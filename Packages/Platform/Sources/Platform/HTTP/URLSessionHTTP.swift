import Foundation
import Kit
import Synchronization

/// The live HTTP service, on `URLSession`.
///
/// The session is ephemeral: no cookies, credentials or cache reach the disk. `HTTPRequest.timeout`
/// is the request's idle timeout as `URLSession` defines it: the longest wait for more data. A
/// streamed body arrives in the chunks the network delivers; cancelling its consumer cancels the
/// request.
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
        let (body, response) = try await session.data(for: Self.urlRequest(for: request))
        let head = try Self.head(of: response)
        return HTTPResponse(status: head.status, headers: head.headers, body: body)
    }

    @concurrent public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let delegate = StreamingTaskDelegate(body: bodyContinuation)
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
        return HTTPStream(status: head.status, headers: head.headers, body: body)
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

    init(body: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.body = body
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
