import Foundation
import Synchronization

/// Answers every request of a session that lists it in `protocolClasses`, so no request reaches the
/// network. Each test stubs its own unique URL under the reserved `.invalid` domain.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// How a stubbed URL answers.
    struct Stub: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// When true the response never finishes, so a test can cancel it.
        var keepsOpen = false
        var failure: URLError.Code?
        /// When set, the URL answers with this redirect status and a `Location` header naming it.
        var redirect: (target: URL, status: Int)?
    }

    private struct Registry {
        var stubs: [URL: Stub] = [:]
        var received: [URL: URLRequest] = [:]
        var receivedBodies: [URL: Data] = [:]
        var stopped: Set<URL> = []
    }

    private static let registry = Mutex(Registry())

    /// A session whose only protocol is this stub.
    static func session() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    /// A unique URL to stub.
    static func uniqueURL(_ path: String = "") -> URL {
        URL(string: "https://stub-\(UUID().uuidString.lowercased()).invalid/\(path)")!
    }

    static func stub(_ url: URL, _ stub: Stub) {
        registry.withLock { $0.stubs[url] = stub }
    }

    static func received(_ url: URL) -> URLRequest? {
        registry.withLock { $0.received[url] }
    }

    static func receivedBody(_ url: URL) -> Data? {
        registry.withLock { $0.receivedBodies[url] }
    }

    static func wasStopped(_ url: URL) -> Bool {
        registry.withLock { $0.stopped.contains(url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let stub = Self.registry.withLock { registry -> Stub? in
            registry.received[url] = request
            registry.receivedBodies[url] = body
            return registry.stubs[url]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        if let redirect = stub.redirect {
            answerWithRedirect(from: url, to: redirect.target, status: redirect.status, stub: stub)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if !stub.keepsOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    /// Reports the redirect, then goes on as if it were the final response. `URLSession` ignores the
    /// rest when its delegate follows the redirect, and delivers it when the delegate refuses: a
    /// protocol that stops after the redirect leaves a refused request waiting forever.
    private func answerWithRedirect(from url: URL, to target: URL, status: Int, stub: Stub) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: stub.headers.merging(["Location": target.absoluteString]) { _, location in location })!
        var next = request
        next.url = target
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        _ = Self.registry.withLock { $0.stopped.insert(url) }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
