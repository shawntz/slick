import Foundation

/// Network requests. Slick makes none unless a feature the user invoked needs one, such as a
/// configured AI provider or currency rates; never on launch, never on a timer the user did not ask
/// for.
public protocol HTTPService: Sendable {
    /// Sends a request and returns the whole response. A status outside 200 to 299 is not an error.
    @concurrent func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Sends a request and streams the body as it arrives, for server-sent events and other streamed
    /// answers. Cancelling the consuming task cancels the request. ``HTTPStream/lines`` and
    /// ``HTTPStream/serverSentEvents`` decode the body.
    @concurrent func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

/// An HTTP request.
public struct HTTPRequest: Hashable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration

    public init(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A complete HTTP response.
public struct HTTPResponse: Hashable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body as UTF-8 text.
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// A response whose body is still arriving.
public struct HTTPStream: Sendable {
    public var status: Int
    public var headers: [String: String]
    /// The body in chunks, in arrival order.
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
