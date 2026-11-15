import Foundation
import Kit
import KitTesting
import Testing

@testable import Platform

/// Kit's redirect rule as a pure decision. Every address is a reserved example name.
@Suite(.timeLimit(.minutes(1))) struct RedirectRuleTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    private static let start = url("https://ai.example.test/v1/messages")

    @Test func theDefaultFollowsOnlyTheSameHostAndPort() {
        let rule = HTTPRequest(Self.start).redirects
        #expect(rule == .sameHost)
        #expect(
            rule.allows(
                redirectFrom: Self.start, to: Self.url("https://ai.example.test/v2/messages"), original: Self.start))
        #expect(
            rule.allows(redirectFrom: Self.start, to: Self.url("https://AI.Example.Test./v2"), original: Self.start))
        #expect(
            rule.allows(redirectFrom: Self.start, to: Self.url("https://ai.example.test:443/v2"), original: Self.start))
        #expect(
            !rule.allows(redirectFrom: Self.start, to: Self.url("https://other.example.test/v1"), original: Self.start))
        #expect(!rule.allows(redirectFrom: Self.start, to: Self.url("https://example.test/v1"), original: Self.start))
        #expect(
            !rule.allows(
                redirectFrom: Self.start, to: Self.url("https://ai.example.test.other.test/v1"), original: Self.start))
        #expect(
            !rule.allows(
                redirectFrom: Self.start, to: Self.url("https://ai.example.test:8443/v1"), original: Self.start))
    }

    @Test func noRuleFollowsHTTPSToPlainHTTP() {
        let plain = Self.url("http://ai.example.test/v1/messages")
        for rule in [HTTPRedirectRule.sameHost, .anyHost, .never] {
            #expect(!rule.allows(redirectFrom: Self.start, to: plain, original: Self.start))
        }
    }

    @Test func plainHTTPMayMoveToHTTPSOnTheStandardPorts() {
        let plain = Self.url("http://model.example.test/v1")
        #expect(
            HTTPRedirectRule.sameHost.allows(
                redirectFrom: plain, to: Self.url("https://model.example.test/v1"), original: plain))
        let local = Self.url("http://localhost:11434/v1")
        #expect(
            !HTTPRedirectRule.sameHost.allows(
                redirectFrom: local, to: Self.url("https://localhost:11434/v1"), original: local))
        #expect(
            HTTPRedirectRule.sameHost.allows(
                redirectFrom: local, to: Self.url("http://localhost:11434/v1/"), original: local))
    }

    @Test func aLaterHopIsJudgedAgainstWhereTheRequestStarted() {
        let plain = Self.url("http://model.example.test/v1")
        let secure = Self.url("https://model.example.test/v1")
        #expect(
            HTTPRedirectRule.sameHost.allows(
                redirectFrom: secure, to: Self.url("https://model.example.test/v2"), original: plain))
        #expect(!HTTPRedirectRule.sameHost.allows(redirectFrom: secure, to: plain, original: plain))
        #expect(
            !HTTPRedirectRule.sameHost.allows(
                redirectFrom: secure, to: Self.url("https://other.example.test/"), original: plain))
    }

    @Test func refusingAndFollowingAnyAreAskedForByName() {
        let sameHost = Self.url("https://ai.example.test/elsewhere")
        let otherHost = Self.url("https://cdn.example.test/image.png")
        #expect(!HTTPRedirectRule.never.allows(redirectFrom: Self.start, to: sameHost, original: Self.start))
        #expect(HTTPRedirectRule.anyHost.allows(redirectFrom: Self.start, to: otherHost, original: Self.start))
    }

    @Test func oddTargetsAreNeverFollowed() {
        for target in [
            "file:///etc/hosts", "ftp://ai.example.test/x", "https://name:secret@ai.example.test/x", "https:///x",
        ] {
            let url = Self.url(target)
            for rule in [HTTPRedirectRule.sameHost, .anyHost] {
                #expect(!rule.allows(redirectFrom: Self.start, to: url, original: Self.start), "\(target)")
            }
        }
    }
}

/// The live service with every request answered by ``StubURLProtocol``. Nothing reaches the network.
@Suite(.timeLimit(.minutes(1))) struct LiveRedirectTests {
    let http = URLSessionHTTP(configuration: StubURLProtocol.session())

    /// A second address on the same host as `url`.
    private static func sameHost(as url: URL, path: String) -> URL {
        URL(string: path, relativeTo: url)!.absoluteURL
    }

    @Test func aRedirectToAnotherHostIsRefusedAndNothingReachesIt() async throws {
        let start = StubURLProtocol.uniqueURL("v1/messages")
        let elsewhere = StubURLProtocol.uniqueURL("collect")
        StubURLProtocol.stub(start, .init(chunks: [Data("moved".utf8)], redirect: (elsewhere, 307)))
        StubURLProtocol.stub(elsewhere, .init(chunks: [Data("taken".utf8)]))
        let request = HTTPRequest(
            start, method: "POST", headers: ["x-api-key": "sample-key"], body: Data("question".utf8))
        let response = try await http.send(request)
        #expect(response.status == 307)
        #expect(response.url == start)
        #expect(response.refusedRedirect == elsewhere)
        #expect(response.headers["Location"] == elsewhere.absoluteString)
        #expect(StubURLProtocol.received(elsewhere) == nil)
    }

    @Test func aRedirectOnTheSameHostIsFollowedAndSaysWhoAnswered() async throws {
        let start = StubURLProtocol.uniqueURL("v1")
        let next = Self.sameHost(as: start, path: "/v2")
        StubURLProtocol.stub(start, .init(redirect: (next, 308)))
        StubURLProtocol.stub(next, .init(chunks: [Data("answer".utf8)]))
        let response = try await http.send(HTTPRequest(start, headers: ["x-api-key": "sample-key"]))
        #expect(response.status == 200)
        #expect(response.text == "answer")
        #expect(response.url == next)
        #expect(response.refusedRedirect == nil)
        #expect(StubURLProtocol.received(next)?.value(forHTTPHeaderField: "x-api-key") == "sample-key")
    }

    @Test func aRequestCanRefuseEveryRedirect() async throws {
        let start = StubURLProtocol.uniqueURL("v1")
        let next = Self.sameHost(as: start, path: "/v2")
        StubURLProtocol.stub(start, .init(redirect: (next, 302)))
        StubURLProtocol.stub(next, .init(chunks: [Data("answer".utf8)]))
        let response = try await http.send(HTTPRequest(start, redirects: .never))
        #expect(response.status == 302)
        #expect(response.refusedRedirect == next)
        #expect(StubURLProtocol.received(next) == nil)
    }

    @Test func aRequestThatNamesAnyHostFollowsElsewhere() async throws {
        let start = StubURLProtocol.uniqueURL("favicon.ico")
        let elsewhere = StubURLProtocol.uniqueURL("favicon.ico")
        StubURLProtocol.stub(start, .init(redirect: (elsewhere, 301)))
        StubURLProtocol.stub(elsewhere, .init(chunks: [Data("image".utf8)]))
        let response = try await http.send(HTTPRequest(start, redirects: .anyHost))
        #expect(response.status == 200)
        #expect(response.url == elsewhere)
    }

    @Test func aDowngradeToPlainHTTPIsRefusedEvenForAnyHost() async throws {
        let start = StubURLProtocol.uniqueURL("v1")
        var components = URLComponents(url: start, resolvingAgainstBaseURL: false)!
        components.scheme = "http"
        let plain = components.url!
        StubURLProtocol.stub(start, .init(redirect: (plain, 301)))
        StubURLProtocol.stub(plain, .init(chunks: [Data("plain".utf8)]))
        let response = try await http.send(HTTPRequest(start, redirects: .anyHost))
        #expect(response.status == 301)
        #expect(response.refusedRedirect == plain)
        #expect(StubURLProtocol.received(plain) == nil)
    }

    @Test func aStreamRefusesARedirectToAnotherHostToo() async throws {
        let start = StubURLProtocol.uniqueURL("v1/chat/completions")
        let elsewhere = StubURLProtocol.uniqueURL("collect")
        StubURLProtocol.stub(
            start,
            .init(headers: ["Content-Type": "text/plain"], chunks: [Data("moved".utf8)], redirect: (elsewhere, 307)))
        StubURLProtocol.stub(
            elsewhere, .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: x\n\n".utf8)]))
        let stream = try await http.stream(
            HTTPRequest(start, method: "POST", headers: ["authorization": "Bearer sample"], body: Data("prompt".utf8)))
        #expect(stream.status == 307)
        #expect(stream.url == start)
        #expect(stream.refusedRedirect == elsewhere)
        #expect(String(decoding: try await stream.data(), as: UTF8.self) == "moved")
        #expect(StubURLProtocol.received(elsewhere) == nil)
    }

    @Test func aStreamFollowsARedirectOnTheSameHost() async throws {
        let start = StubURLProtocol.uniqueURL("v1/events")
        let next = Self.sameHost(as: start, path: "/v1/events/")
        StubURLProtocol.stub(start, .init(redirect: (next, 307)))
        StubURLProtocol.stub(
            next, .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: one\n\n".utf8)]))
        let stream = try await http.stream(HTTPRequest(start))
        #expect(stream.status == 200)
        #expect(stream.url == next)
        #expect(stream.refusedRedirect == nil)
        var events: [String] = []
        for try await event in stream.serverSentEvents {
            events.append(event.data)
        }
        #expect(events == ["one"])
    }
}

/// The fake plays redirects under the same rule, so a feature's tests can see what would leak.
@Suite(.timeLimit(.minutes(1))) struct FakeHTTPRedirectTests {
    private static let start = URL(string: "https://ai.example.test/v1/messages")!
    private static let elsewhere = URL(string: "https://collector.example.test/take")!

    @Test func aRefusedRedirectNeverRequestsTheOtherHost() async throws {
        let http = FakeHTTP()
        http.stubRedirect(Self.start, to: Self.elsewhere)
        http.stub(Self.elsewhere, response: HTTPResponse(status: 200))
        let response = try await http.send(HTTPRequest(Self.start, headers: ["x-api-key": "sample-key"]))
        #expect(response.status == 307)
        #expect(response.refusedRedirect == Self.elsewhere)
        #expect(response.url == Self.start)
        #expect(http.requests.map(\.url) == [Self.start])
        let stream = try await http.stream(HTTPRequest(Self.start))
        #expect(stream.status == 307)
        #expect(stream.refusedRedirect == Self.elsewhere)
        #expect(stream.headers["Location"] == Self.elsewhere.absoluteString)
    }

    @Test func aFollowedRedirectCarriesTheHeadersAndShowsUpAsARequest() async throws {
        let http = FakeHTTP()
        let next = URL(string: "https://ai.example.test/v2/messages")!
        http.stubRedirect(Self.start, to: URL(string: "/v2/messages")!, status: 308)
        http.stub(next, status: 200, chunks: ["data: one\n\n"])
        let stream = try await http.stream(
            HTTPRequest(Self.start, method: "POST", headers: ["x-api-key": "sample-key"], body: Data("q".utf8)))
        #expect(stream.status == 200)
        #expect(stream.url == next)
        #expect(http.requests.map(\.url) == [Self.start, next])
        #expect(http.requests.last?.headers["x-api-key"] == "sample-key")
        #expect(http.requests.last?.method == "POST")
        #expect(http.requests.last?.body == Data("q".utf8))
    }

    @Test func anyHostFollowsAndASeeOtherBecomesAGet() async throws {
        let http = FakeHTTP()
        http.stubRedirect(Self.start, to: Self.elsewhere, status: 303)
        http.stub(Self.elsewhere, response: HTTPResponse(status: 200, body: Data("ok".utf8)))
        let response = try await http.send(
            HTTPRequest(Self.start, method: "POST", body: Data("q".utf8), redirects: .anyHost))
        #expect(response.text == "ok")
        #expect(response.url == Self.elsewhere)
        #expect(http.requests.last?.method == "GET")
        #expect(http.requests.last?.body == nil)
    }

    @Test func aLoopOfRedirectsFailsInsteadOfSpinning() async {
        let http = FakeHTTP()
        let other = URL(string: "https://ai.example.test/loop")!
        http.stubRedirect(Self.start, to: other)
        http.stubRedirect(other, to: Self.start)
        await #expect(throws: URLError.self) { try await http.send(HTTPRequest(Self.start)) }
        #expect(http.requests.count == FakeHTTP.maximumRedirects + 1)
    }

    @Test func aStreamKeepsAStubbedResponsesHeaders() async throws {
        let http = FakeHTTP()
        http.stub(
            Self.start,
            response: HTTPResponse(status: 429, headers: ["retry-after": "7"], body: Data("{\"error\":{}}".utf8)))
        let stream = try await http.stream(HTTPRequest(Self.start))
        #expect(stream.status == 429)
        #expect(stream.headers["retry-after"] == "7")
        #expect(stream.url == Self.start)
        #expect(try await stream.data() == Data("{\"error\":{}}".utf8))
    }
}

/// Remote images carry nothing private, so their downloads follow a redirect to another host.
@Suite(.timeLimit(.minutes(1))) struct RemoteImageRedirectTests {
    let folder = TemporaryFolder()
    let http = FakeHTTP()

    func makeStore() -> RemoteImageStore {
        RemoteImageStore(folder: folder.url, http: http, settings: PlatformSettings(backend: MemorySettingsBackend()))
    }

    @Test func anIconMovedToAnotherHostStillDownloads() async throws {
        let start = try #require(URL(string: "https://example.com/favicon.ico"))
        let moved = try #require(URL(string: "https://www.example.com/favicon.ico"))
        let png = try pngData(red: 1, green: 2, blue: 3)
        http.stubRedirect(start, to: moved, status: 301)
        http.stub(moved, response: HTTPResponse(status: 200, body: png))
        #expect(await makeStore().data(for: start) == png)
        #expect(http.requests.map(\.url) == [start, moved])
        withExtendedLifetime(folder) {}
    }

    @Test func anIconMovedToPlainHTTPIsNotFetched() async throws {
        let start = try #require(URL(string: "https://example.com/favicon.ico"))
        let plain = try #require(URL(string: "http://example.com/favicon.ico"))
        http.stubRedirect(start, to: plain, status: 301)
        http.stub(plain, response: HTTPResponse(status: 200, body: try pngData(red: 1, green: 2, blue: 3)))
        #expect(await makeStore().data(for: start) == nil)
        #expect(http.requests.map(\.url) == [start])
        withExtendedLifetime(folder) {}
    }
}
