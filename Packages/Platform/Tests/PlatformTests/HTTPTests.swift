import Foundation
import Kit
import Testing

@testable import Platform

/// Every request goes to ``StubURLProtocol``; nothing reaches the network.
@Suite(.timeLimit(.minutes(1))) struct HTTPTests {
    let http = URLSessionHTTP(configuration: StubURLProtocol.session())

    @Test func sendDeliversTheRequestAndReturnsTheResponse() async throws {
        let url = StubURLProtocol.uniqueURL("items")
        StubURLProtocol.stub(
            url, .init(status: 201, headers: ["Content-Type": "application/json"], chunks: [Data("{\"ok\":true}".utf8)])
        )
        let response = try await http.send(
            HTTPRequest(url, method: "POST", headers: ["X-Sample": "1"], body: Data("payload".utf8)))
        #expect(response.status == 201)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.text == "{\"ok\":true}")
        let received = try #require(StubURLProtocol.received(url))
        #expect(received.httpMethod == "POST")
        #expect(received.value(forHTTPHeaderField: "X-Sample") == "1")
        #expect(StubURLProtocol.receivedBody(url) == Data("payload".utf8))
    }

    @Test func aStatusOutsideTwoHundredIsNotAnError() async throws {
        let url = StubURLProtocol.uniqueURL()
        StubURLProtocol.stub(url, .init(status: 404, chunks: [Data("missing".utf8)]))
        let response = try await http.send(HTTPRequest(url))
        #expect(response.status == 404)
        #expect(response.text == "missing")
    }

    @Test func aNetworkFailureThrows() async {
        let url = StubURLProtocol.uniqueURL()
        StubURLProtocol.stub(url, .init(failure: .notConnectedToInternet))
        await #expect(throws: URLError.self) { try await http.send(HTTPRequest(url)) }
        await #expect(throws: URLError.self) { try await http.stream(HTTPRequest(url)) }
    }

    @Test func aStreamDeliversTheHeadThenTheBody() async throws {
        let url = StubURLProtocol.uniqueURL("events")
        let chunks = ["data: one\n\n", "data: two\n\n", "data: three\n\n"].map { Data($0.utf8) }
        StubURLProtocol.stub(url, .init(headers: ["Content-Type": "text/event-stream"], chunks: chunks))
        let stream = try await http.stream(HTTPRequest(url))
        #expect(stream.status == 200)
        #expect(stream.headers["Content-Type"] == "text/event-stream")
        var events: [String] = []
        for try await event in stream.serverSentEvents {
            events.append(event.data)
        }
        #expect(events == ["one", "two", "three"])
    }

    @Test func cancellingTheConsumerCancelsTheRequest() async throws {
        let url = StubURLProtocol.uniqueURL("open")
        // URLSession holds back the head of a response without a content type until it has sniffed
        // enough of the body, so a real streamed answer always names its type.
        StubURLProtocol.stub(
            url, .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("first".utf8)], keepsOpen: true))
        let stream = try await http.stream(HTTPRequest(url))
        let (gotFirst, firstContinuation) = AsyncStream.makeStream(of: Data.self)
        let consumer = Task {
            for try await chunk in stream.body {
                firstContinuation.yield(chunk)
            }
        }
        var iterator = gotFirst.makeAsyncIterator()
        #expect(await iterator.next() == Data("first".utf8))
        consumer.cancel()
        _ = await consumer.result
        try await waitUntil { StubURLProtocol.wasStopped(url) }
    }

    @Test func requestsCarryTheTimeoutAsTheIdleInterval() {
        let request = URLSessionHTTP.urlRequest(
            for: HTTPRequest(URL(string: "https://example.invalid")!, timeout: .milliseconds(1500)))
        #expect(request.timeoutInterval == 1.5)
        #expect(request.httpMethod == "GET")
    }
}
