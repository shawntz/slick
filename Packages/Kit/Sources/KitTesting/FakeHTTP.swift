import Foundation
import Kit
import Synchronization

/// An HTTP client with no network. A test stubs each URL; any other request fails with
/// ``FakeHTTPError/notStubbed(_:)``.
public final class FakeHTTP: HTTPService {
    /// Answers one request, such as the second turn of a conversation differently from the first.
    public typealias Handler = @Sendable (HTTPRequest) -> FakeHTTPReply

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

    /// Answers requests to the URL with whatever the handler returns for each.
    public func stub(_ url: URL, handler: @escaping Handler) {
        state.withLock { $0.stubs[url] = handler }
    }

    /// Every request, in order.
    public var requests: [HTTPRequest] { state.withLock { $0.requests } }

    /// Streamed requests whose consumer stopped reading before the body finished.
    public var cancelledRequests: [HTTPRequest] { state.withLock { $0.cancelled } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch try reply(to: request) {
        case .response(let response): return response
        case .chunks(let chunks, let status, _): return HTTPResponse(status: status, body: Data(chunks.joined().utf8))
        case .failure(let error): throw error
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (status, chunks, keepsOpen): (Int, [Data], Bool)
        switch try reply(to: request) {
        case .response(let response): (status, chunks, keepsOpen) = (response.status, [response.body], false)
        case .chunks(let parts, let code, let open):
            (status, chunks, keepsOpen) = (code, parts.map { Data($0.utf8) }, open)
        case .failure(let error): throw error
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if !keepsOpen { continuation.finish() }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.state.withLock { $0.cancelled.append(request) } }
            }
        }
        return HTTPStream(status: status, body: body)
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
    /// A whole response.
    case response(HTTPResponse)
    /// A streamed body in chunks. With `keepsOpen`, the stream stays open after the last chunk.
    case chunks([String], status: Int = 200, keepsOpen: Bool = false)
    /// The request fails with this error, as when the network is down.
    case failure(any Error)
}

/// Why a ``FakeHTTP`` request failed.
public enum FakeHTTPError: Error, Hashable, Sendable {
    case notStubbed(URL)
}
