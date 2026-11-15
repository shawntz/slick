import Foundation
import Kit
import Synchronization

/// An HTTP client with no network. A test stubs each URL; any other request fails with
/// ``FakeHTTPError/notStubbed(_:)``.
///
/// A stub can answer with a redirect, which the fake plays under the request's
/// ``HTTPRequest/redirects`` rule, as the live service does: a followed redirect is one more entry
/// in ``requests``, with the same headers, and a refused one comes back as the 3xx response with
/// ``HTTPResponse/refusedRedirect`` set. Responses say which address answered in
/// ``HTTPResponse/url``.
public final class FakeHTTP: HTTPService {
    /// Answers one request, such as the second turn of a conversation differently from the first.
    public typealias Handler = @Sendable (HTTPRequest) -> FakeHTTPReply

    /// The most redirects one request follows before it fails, as `URLSession` does.
    public static let maximumRedirects = 16

    private struct State {
        var stubs: [URL: Handler] = [:]
        var requests: [HTTPRequest] = []
        var cancelled: [HTTPRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Answers requests to the URL with a response.
    public func stub(_ url: URL, response: HTTPResponse) {
        stub(url) { _ in .response(response) }
    }

    /// Answers requests to the URL with a body that arrives in chunks, for streamed answers. With
    /// `keepsOpen`, the body never finishes, so a test can stop it.
    public func stub(_ url: URL, status: Int = 200, chunks: [String], keepsOpen: Bool = false) {
        stub(url) { _ in .chunks(chunks, status: status, keepsOpen: keepsOpen) }
    }

    /// Answers requests to the URL with a redirect to `target`, which may be relative.
    public func stubRedirect(_ url: URL, to target: URL, status: Int = 307) {
        stub(url) { _ in .redirect(to: target, status: status) }
    }

    /// Answers requests to the URL with whatever the handler returns for each.
    public func stub(_ url: URL, handler: @escaping Handler) {
        state.withLock { $0.stubs[url] = handler }
    }

    /// Every request, in order. A followed redirect adds the request it led to.
    public var requests: [HTTPRequest] { state.withLock { $0.requests } }

    /// Streamed requests whose consumer stopped reading before the body finished.
    public var cancelledRequests: [HTTPRequest] { state.withLock { $0.cancelled } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (answer, answered) = try play(request)
        switch answer {
        case .response(var response):
            response.url = response.url ?? answered.url
            return response
        case .chunks(let chunks, let status, _):
            return HTTPResponse(status: status, body: Data(chunks.joined().utf8), url: answered.url)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (answer, answered) = try play(request)
        let head: (status: Int, headers: [String: String], refusedRedirect: URL?)
        let (chunks, keepsOpen): ([Data], Bool)
        switch answer {
        case .response(let response):
            head = (response.status, response.headers, response.refusedRedirect)
            (chunks, keepsOpen) = ([response.body], false)
        case .chunks(let parts, let code, let open):
            head = (code, [:], nil)
            (chunks, keepsOpen) = (parts.map { Data($0.utf8) }, open)
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if !keepsOpen { continuation.finish() }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.state.withLock { $0.cancelled.append(answered) } }
            }
        }
        return HTTPStream(
            status: head.status, headers: head.headers, body: body, url: answered.url,
            refusedRedirect: head.refusedRedirect)
    }

    /// What a request ends with once every redirect was followed or refused.
    private enum Answer {
        case response(HTTPResponse)
        case chunks([String], status: Int, keepsOpen: Bool)
    }

    /// Answers the request, following redirects its rule allows. Returns the final answer and the
    /// request that got it. A refused redirect comes back as a response with its 3xx status.
    private func play(_ request: HTTPRequest) throws -> (Answer, HTTPRequest) {
        var current = request
        var followed = 0
        while true {
            let location: URL
            let status: Int
            switch try reply(to: current) {
            case .response(let response): return (.response(response), current)
            case .chunks(let chunks, let code, let keepsOpen):
                return (.chunks(chunks, status: code, keepsOpen: keepsOpen), current)
            case .failure(let error): throw error
            case .redirect(let to, let code): (location, status) = (to, code)
            }
            let target = URL(string: location.relativeString, relativeTo: current.url)?.absoluteURL ?? location
            guard request.redirects.allows(redirectFrom: current.url, to: target, original: request.url) else {
                let refused = HTTPResponse(
                    status: status, headers: ["Location": location.absoluteString], url: current.url,
                    refusedRedirect: target)
                return (.response(refused), current)
            }
            followed += 1
            guard followed <= Self.maximumRedirects else { throw URLError(.httpTooManyRedirects) }
            current = Self.redirected(current, to: target, status: status)
        }
    }

    /// The request a redirect leads to. 307 and 308 keep the method and body. 303, and 301 or 302
    /// after a POST, become a GET without a body, as `URLSession` does. Every header goes along.
    private static func redirected(_ request: HTTPRequest, to target: URL, status: Int) -> HTTPRequest {
        var next = request
        next.url = target
        let becomesGet = status == 303 || ((status == 301 || status == 302) && request.method.uppercased() == "POST")
        if becomesGet, request.method.uppercased() != "HEAD" {
            next.method = "GET"
            next.body = nil
        }
        return next
    }

    private func reply(to request: HTTPRequest) throws -> FakeHTTPReply {
        let handler = state.withLock { state in
            state.requests.append(request)
            return state.stubs[request.url]
        }
        guard let handler else { throw FakeHTTPError.notStubbed(request.url) }
        return handler(request)
    }
}

/// What a ``FakeHTTP`` stub answers.
public enum FakeHTTPReply: Sendable {
    /// A whole response. A stream keeps its status and headers.
    case response(HTTPResponse)
    /// A streamed body in chunks. With `keepsOpen`, the stream stays open after the last chunk.
    case chunks([String], status: Int = 200, keepsOpen: Bool = false)
    /// The request fails with this error, as when the network is down.
    case failure(any Error)
    /// A redirect to `to`, which may be relative to the request's URL. The fake follows it when the
    /// request's ``HTTPRequest/redirects`` rule allows, and answers with this status otherwise.
    case redirect(to: URL, status: Int = 307)
}

/// Why a ``FakeHTTP`` request failed.
public enum FakeHTTPError: Error, Hashable, Sendable {
    case notStubbed(URL)
}
