import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("Anthropic provider", .timeLimit(.minutes(1)))
@MainActor
struct AnthropicTests {
    @Test func streamsAnAnswerWithTheDocumentedRequest() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Glass ", "is ", "amorphous."]))
        try await ai.harness.run("ask", arguments: ["prompt": "what is glass"], launch: .tabFromRoot)

        #expect(ai.shownText == "> what is glass\n\nGlass is amorphous.")
        #expect(
            ai.harness.detail?.metadata == [
                .label("Model", value: "Claude Opus 5.5"), .label("Sent To", value: "api.anthropic.com"),
            ])
        let request = try #require(ai.fakes.http.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.method == "POST")
        #expect(request.headers["x-api-key"] == AIHarness.anthropicKey)
        #expect(request.headers["anthropic-version"] == "2026-10-21")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        let body = try ai.requestBody()
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 16_000)
        #expect(body["system"] as? String == Prompts.defaultSystem)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["temperature"] == nil && body["thinking"] == nil)
        #expect(try ai.sentMessages() == [["user", "what is glass"]])
        #expect(ai.session?.conversation.messages.last?.ending == nil)
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func haikuGetsNoFallbacks() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        try await ai.useAnthropic(model: .haiku)
        ai.stubAnthropic(AnthropicSSE.answer(["Hi."]))
        try await ai.harness.run("ask", arguments: ["prompt": "hello"])
        let body = try ai.requestBody()
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["fallbacks"] == nil)
        #expect(ai.fakes.http.requests.first?.headers["anthropic-beta"] == nil)
    }

    @Test func eventsSplitAcrossChunksAnywhereStillParse() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        let whole = AnthropicSSE.answer(["Split ", "streams ", "work."]).joined()
        // Cut every 7 bytes of ASCII text, through field names, JSON and blank lines.
        var chunks: [String] = []
        var rest = Substring(whole)
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(7)))
            rest = rest.dropFirst(7)
        }
        ai.stubAnthropic(chunks)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText == "> q\n\nSplit streams work.")
    }

    @Test func aCharacterSplitAcrossChunksArrivesWhole() async throws {
        let text = "Größe 🇩🇪 日本"
        let body = Data(AnthropicSSE.answer([text]).joined().utf8)
        // Split inside every multi-byte character: the byte after each lead byte starts a new chunk.
        var chunks: [Data] = []
        var start = body.startIndex
        for index in body.indices where body[index] >= 0xC0 {
            chunks.append(body[start...index])
            start = index + 1
        }
        chunks.append(body[start...])
        #expect(chunks.count > 5)
        let provider = AnthropicProvider(http: ByteChunkHTTP(status: 200, chunks: chunks), apiKey: "k", model: .opus)
        var received = ""
        for try await event in provider.stream(ModelRequest(system: "", turns: [ModelTurn(.user, "q")], length: .short))
        {
            if case .text(let piece) = event { received += piece }
        }
        #expect(received == text)
        #expect(!received.contains("\u{FFFD}"))
    }

    @Test func aStreamThatStopsMidEventKeepsTheTextAndSaysItWasCutOff() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        let truncated = String(AnthropicSSE.textDelta("lost", index: 0).prefix(40))
        ai.stubAnthropic([
            AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0), AnthropicSSE.textDelta("Half an ", index: 0),
            truncated,
        ])
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.hasPrefix("> q\n\nHalf an \n\n**Answer Cut Off**"))
        #expect(ai.session?.conversation.messages.last?.ending == .failed(Strings.Failures.cutOff))
        #expect(ai.session?.conversation.messages.last?.text == "Half an ")
        #expect(ai.harness.actions().map(\.title).contains("Regenerate"))
    }

    @Test func aWrongKeySaysWhatToDo() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(
            [AnthropicSSE.errorBody(type: "authentication_error", message: "invalid x-api-key")], status: 401)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**API Key Not Accepted**"))
        #expect(ai.shownText.contains("Check it in AI settings"))
        #expect(!ai.shownText.contains(AIHarness.anthropicKey))
    }

    @Test func rateLimitsSayHowLongToWait() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic([AnthropicSSE.errorBody(type: "rate_limit_error", message: "slow down")], status: 429)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Rate Limited**\n\nWait a minute, then press Regenerate."))

        // FakeHTTP drops headers from streamed responses, so the retry-after header goes through a
        // service of the test's own.
        let http = ByteChunkHTTP(
            status: 429, headers: ["Retry-After": "20"],
            chunks: [Data(AnthropicSSE.errorBody(type: "rate_limit_error", message: "slow down").utf8)])
        let provider = AnthropicProvider(http: http, apiKey: "k", model: .opus)
        let request = ModelRequest(system: "", turns: [ModelTurn(.user, "q")], length: .short)
        await #expect(throws: Strings.Failures.rateLimited(after: 20)) {
            for try await _ in provider.stream(request) {}
        }
        #expect(Strings.Failures.rateLimited(after: 20).message == "Wait 20 seconds, then press Regenerate.")
    }

    @Test func anOverloadedServerBeforeOrDuringTheAnswer() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic([AnthropicSSE.errorBody(type: "overloaded_error", message: "Overloaded")], status: 529)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Anthropic Is Busy**"))

        ai.stubAnthropic([
            AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0), AnthropicSSE.textDelta("Partial", index: 0),
            AnthropicSSE.error(type: "overloaded_error", message: "Overloaded"),
        ])
        try await ai.harness.run("ask", arguments: ["prompt": "again"])
        #expect(ai.shownText.hasPrefix("> again\n\nPartial\n\n**Anthropic Is Busy**"))
        #expect(ai.session?.conversation.messages.last?.text == "Partial")
    }

    @Test func otherStatusesHaveTheirOwnWords() async throws {
        let cases: [(Int, String, String)] = [
            (400, "invalid_request_error", "Request Not Accepted"),
            (402, "billing_error", "Billing Problem"),
            (403, "permission_error", "Access Denied"),
            (404, "not_found_error", "Model Not Available"),
            (413, "request_too_large", "Conversation Too Long"),
            (500, "api_error", "Anthropic Had a Problem"),
            (502, "", "Anthropic Had a Problem"),
        ]
        for (status, type, title) in cases {
            let ai = try await AIHarness(provider: .anthropic)
            ai.stubAnthropic(
                [type.isEmpty ? "<html>Bad gateway</html>" : AnthropicSSE.errorBody(type: type, message: "detail")],
                status: status)
            try await ai.harness.run("ask", arguments: ["prompt": "q"])
            #expect(ai.shownText.contains("**\(title)**"), "status \(status)")
        }
    }

    @Test func noNetworkSaysToConnect() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.fakes.http.stub(AnthropicProvider.endpoint) { _ in .failure(URLError(.notConnectedToInternet)) }
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**No Internet Connection**\n\nConnect to the internet, then press Regenerate."))
    }

    @Test func lengthLimitAndRefusalEndWithANote() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Long"], stopReason: "max_tokens"))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Answer Reached the Length Limit**"))
        #expect(ai.session?.conversation.messages.last?.ending == .lengthLimit)

        ai.stubAnthropic(AnthropicSSE.answer([], stopReason: "refusal"))
        try await ai.harness.run("ask", arguments: ["prompt": "q2"])
        #expect(ai.shownText.contains("**The Model Declined to Answer**"))
    }

    @Test func thinkingBlocksGoBackWithTheNextTurn() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["First."], signature: "c2lnbmF0dXJl"))
        try await ai.harness.run("ask", arguments: ["prompt": "one"])
        #expect(ai.session?.conversation.messages.last?.replay == [.thinking("", signature: "c2lnbmF0dXJl")])

        ai.stubAnthropic(AnthropicSSE.answer(["Second."]))
        try await ai.harness.followUp("two")
        #expect(try ai.sentMessages(1) == [["user", "one"], ["assistant", "thinking,text"], ["user", "two"]])
        let messages = try #require(try ai.requestBody(1)["messages"] as? [[String: Any]])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks[0]["signature"] as? String == "c2lnbmF0dXJl")
        #expect(blocks[0]["thinking"] as? String == "")
        #expect(blocks[1]["text"] as? String == "First.")
        #expect(ai.shownText == "> one\n\nFirst.\n\n---\n\n> two\n\nSecond.")
    }

    @Test func aFallbackMidAnswerKeepsNoThinkingToSendBack() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        var chunks = [AnthropicSSE.messageStart()]
        chunks += AnthropicSSE.thinkingBlock(index: 0, signature: "Zmlyc3Q=")
        chunks += [
            AnthropicSSE.textStart(index: 1), AnthropicSSE.textDelta("Start ", index: 1),
            AnthropicSSE.blockStop(index: 1),
            AnthropicSSE.event(
                "content_block_start",
                [
                    "type": "content_block_start", "index": 2,
                    "content_block": [
                        "type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-4-8"],
                    ],
                ]),
            AnthropicSSE.blockStop(index: 2),
            AnthropicSSE.textStart(index: 3), AnthropicSSE.textDelta("and finish.", index: 3),
            AnthropicSSE.blockStop(index: 3),
        ]
        chunks += AnthropicSSE.messageEnd()
        ai.stubAnthropic(chunks)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText == "> q\n\nStart and finish.")
        #expect(ai.session?.conversation.messages.last?.replay == nil)
    }

    @Test func stoppingCancelsTheRequestAndKeepsWhatArrived() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(
            [AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0), AnthropicSSE.textDelta("Hello", index: 0)],
            keepsOpen: true)
        let session = AIFeature.askSession("q", services: ai.feature.services)
        var detail = Detail()
        var iterator = session.start().makeAsyncIterator()
        while let update = try await iterator.next() {
            detail.apply(update)
            if case .markdown(let text) = detail.body, text.hasSuffix("Hello") { break }
        }
        #expect(session.isStreaming)
        let actions = session.actions(for: detail)
        #expect(actions.map(\.title) == ["Stop"])
        try await ai.harness.perform(try #require(actions.first), row: nil)
        while let update = try await iterator.next() { detail.apply(update) }

        #expect(detail.body == .markdown("> q\n\nHello\n\n**Stopped**"))
        #expect(session.conversation.messages.last?.text == "Hello")
        #expect(session.conversation.messages.last?.ending == .stopped)
        #expect(session.actions(for: detail).map(\.title).contains("Regenerate"))
        try await eventually { ai.fakes.http.cancelledRequests.count == 1 }
    }
}
