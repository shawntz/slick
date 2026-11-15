import Foundation

/// Network requests. Slick makes none unless a feature the user invoked needs one, such as a
/// configured AI provider or currency rates; never on launch, never on a timer the user did not ask
/// for.
///
/// Redirects follow the request's ``HTTPRequest/redirects`` rule, ``HTTPRedirectRule/sameHost`` by
/// default, so a request that carries a key or private text reaches only the host its feature named.
/// A redirect the rule refuses is not followed: the response is the redirect itself, and its
/// ``HTTPResponse/refusedRedirect`` says where it pointed.
public protocol HTTPService: Sendable {
    /// Sends a request and returns the whole response. A status outside 200 to 299 is not an error.
    @concurrent func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Sends a request and streams the body as it arrives, for server-sent events and other streamed
    /// answers. Cancelling the consuming task cancels the request. ``HTTPStream/lines`` and
    /// ``HTTPStream/serverSentEvents`` decode the body. Redirects follow the same rule as ``send(_:)``.
    @concurrent func stream(_ request: HTTPRequest) async throws -> HTTPStream
}

/// An HTTP request.
public struct HTTPRequest: Hashable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration
    /// Which redirects the service follows. Same host only by default.
    public var redirects: HTTPRedirectRule

    public init(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(30),
        redirects: HTTPRedirectRule = .sameHost
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.redirects = redirects
    }
}

/// Which redirects a request follows. A redirect carries the request's headers and, for 307 and 308,
/// its method and body to the new address, so a key or a prompt goes wherever the redirect points.
///
/// No rule follows a redirect from `https` to `http`, to a scheme other than `http` or `https`, or to
/// an address with a user name or password in it.
public struct HTTPRedirectRule: Hashable, Sendable {
    private enum Kind: Hashable, Sendable {
        case sameHost
        case never
        case anyHost
    }

    private let kind: Kind

    private init(_ kind: Kind) {
        self.kind = kind
    }

    /// The default. Follows a redirect only to the host the request started at, on the same port.
    /// Moving from `http` to `https` on the standard ports counts as the same place.
    public static let sameHost = HTTPRedirectRule(.sameHost)

    /// Follows no redirect.
    public static let never = HTTPRedirectRule(.never)

    /// Follows a redirect to any host, as browsers do. For requests that carry nothing private, such
    /// as a public image. Name it only where a redirect to another host is expected.
    public static let anyHost = HTTPRedirectRule(.anyHost)

    /// True when a request that started at `original`, and was answered with a redirect at
    /// `current`, may go on to `target`.
    public func allows(redirectFrom current: URL, to target: URL, original: URL) -> Bool {
        guard let currentScheme = Self.scheme(of: current), let targetScheme = Self.scheme(of: target),
            target.user == nil, target.password == nil, Self.host(of: target) != nil
        else { return false }
        if currentScheme == "https", targetScheme == "http" { return false }
        switch kind {
        case .never:
            return false
        case .anyHost:
            return true
        case .sameHost:
            guard let host = Self.host(of: target), host == Self.host(of: original), host == Self.host(of: current)
            else { return false }
            let currentPort = Self.port(of: current, scheme: currentScheme)
            let targetPort = Self.port(of: target, scheme: targetScheme)
            if currentScheme == targetScheme { return currentPort == targetPort }
            // Only http to https is left: the plain port moving to the secure one.
            return currentPort == 80 && targetPort == 443
        }
    }

    /// `http` or `https`, lowercased, or nil for any other scheme.
    private static func scheme(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return scheme
    }

    /// The host without case or a trailing dot, or nil when there is none.
    private static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func port(of url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// A complete HTTP response.
public struct HTTPResponse: Hashable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// The address that answered: the request's own, or the last one a redirect led to. Nil when
    /// the response was made by hand.
    public var url: URL?
    /// Where a redirect the request's rule refused pointed. The response is then that redirect, with
    /// its 3xx status, and nothing was sent to this address.
    public var refusedRedirect: URL?

    public init(
        status: Int, headers: [String: String] = [:], body: Data = Data(), url: URL? = nil,
        refusedRedirect: URL? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.refusedRedirect = refusedRedirect
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
    /// The address that answered, as ``HTTPResponse/url`` says.
    public var url: URL?
    /// Where a refused redirect pointed, as ``HTTPResponse/refusedRedirect`` says.
    public var refusedRedirect: URL?

    public init(
        status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>, url: URL? = nil,
        refusedRedirect: URL? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.refusedRedirect = refusedRedirect
    }
}
