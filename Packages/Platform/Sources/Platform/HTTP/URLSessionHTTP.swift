import Foundation
import Kit
import Synchronization

/// The live HTTP service, on `URLSession`.
///
/// The session is ephemeral: no cookies, credentials or cache reach the disk. `HTTPRequest.timeout`
/// is the request's idle timeout as `URLSession` defines it: the longest wait for more data. A
/// streamed body arrives in the chunks the network delivers; cancelling its consumer cancels the
/// request.
///
/// Each request carries a task delegate that answers `URLSession`'s redirect question with the
/// request's ``HTTPRequest/redirects`` rule. A refused redirect ends the request with the redirect
/// response itself, as `URLSession` does when the delegate answers nil, and the response names the
/// refused address in ``HTTPResponse/refusedRedirect``. Nothing is sent to that address. Redirects
/// that the network stack makes by itself, such as an HSTS upgrade from `http` to `https` on the same
/// host, ask the same question.
nonisolated public final class URLSessionHTTP: HTTPService {
    private let session: URLSession

    /// - Parameter configuration: The session configuration. Defaults to an ephemeral one. Tests
    ///   pass one whose `protocolClasses` hold a stub, so no request reaches the network.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    @concurrent public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let gate = RedirectGate(request)
        let (body, response) = try await session.data(for: Self.urlRequest(for: request), delegate: gate)
        let head = try Self.head(of: response)
        return HTTPResponse(
            status: head.status, headers: head.headers, body: body, url: response.url,
            refusedRedirect: gate.refused(answering: head.status))
    }

    @concurrent public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let delegate = StreamingTaskDelegate(body: bodyContinuation, redirects: RedirectGate(request))
        let task = session.dataTask(with: Self.urlRequest(for: request))
        task.delegate = delegate
        bodyContinuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.waitForHead(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        let head = try Self.head(of: response)
        return HTTPStream(
            status: head.status, headers: head.headers, body: body, url: response.url,
            refusedRedirect: delegate.redirects.refused(answering: head.status))
    }

    static func urlRequest(for request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout.timeInterval)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    static func head(of response: URLResponse) throws -> (status: Int, headers: [String: String]) {
        guard let response = response as? HTTPURLResponse else { throw HTTPServiceError.notHTTP }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        return (response.statusCode, headers)
    }
}

/// Answers `URLSession`'s redirect question for one request with the request's rule, and remembers
/// the address it refused.
nonisolated final class RedirectGate: NSObject, URLSessionTaskDelegate, Sendable {
    private let rule: HTTPRedirectRule
    private let original: URL
    private let refused = Mutex<URL?>(nil)

    init(_ request: HTTPRequest) {
        rule = request.redirects
        original = request.url
    }

    /// The request to follow the redirect with, or nil to stop at the redirect. `current` is the
    /// address that answered with the redirect.
    func decide(from current: URL?, to proposed: URLRequest) -> URLRequest? {
        guard let target = proposed.url else { return nil }
        if let current, rule.allows(redirectFrom: current, to: target, original: original) { return proposed }
        refused.withLock { $0 = target }
        return nil
    }

    /// The refused address, when the final response is the redirect that was refused.
    func refused(answering status: Int) -> URL? {
        (300..<400).contains(status) ? refused.withLock { $0 } : nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(decide(from: response.url ?? task.currentRequest?.url, to: request))
    }
}

/// Why a request failed without an HTTP status.
nonisolated public enum HTTPServiceError: Error, Hashable, Sendable {
    /// The server answered with something other than HTTP.
    case notHTTP
}

/// Receives one streamed request's events: the response head once, then body chunks.
nonisolated final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var head: CheckedContinuation<URLResponse, any Error>?
        var receivedHead = false
    }

    private let body: AsyncThrowingStream<Data, any Error>.Continuation
    private let state = Mutex(State())
    /// The request's redirect rule, asked before any redirect is followed.
    let redirects: RedirectGate

    init(body: AsyncThrowingStream<Data, any Error>.Continuation, redirects: RedirectGate) {
        self.body = body
        self.redirects = redirects
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(redirects.decide(from: response.url ?? task.currentRequest?.url, to: request))
    }

    func waitForHead(_ continuation: CheckedContinuation<URLResponse, any Error>) {
        state.withLock { $0.head = continuation }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let head = state.withLock { state -> CheckedContinuation<URLResponse, any Error>? in
            state.receivedHead = true
            defer { state.head = nil }
            return state.head
        }
        head?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let head = state.withLock { state -> CheckedContinuation<URLResponse, any Error>? in
            defer { state.head = nil }
            return state.head
        }
        let failure = error.map(Self.cancellationAware)
        head?.resume(throwing: failure ?? HTTPServiceError.notHTTP)
        if let failure {
            body.finish(throwing: failure)
        } else {
            body.finish()
        }
    }

    /// `URLError.cancelled` becomes `CancellationError`, the error Kit's callers expect.
    private static func cancellationAware(_ error: any Error) -> any Error {
        (error as? URLError)?.code == .cancelled ? CancellationError() : error
    }
}
