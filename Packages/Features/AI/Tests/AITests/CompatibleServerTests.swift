import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("OpenAI-compatible server", .timeLimit(.minutes(1)))
@MainActor
struct CompatibleServerTests {
    @Test func streamsFromALocalServerWithoutAKey() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer(CompletionSSE.answer(["Local ", "answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "hello"])

        #expect(ai.shownText == "> hello\n\nLocal answer.")
        #expect(ai.harness.detail?.metadata.last == .label("Sent To", value: "localhost"))
        let request = try #require(ai.fakes.http.requests.first)
        #expect(request.url == AIHarness.serverURL)
        #expect(request.headers["authorization"] == nil)
        let body = try ai.requestBody()
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 4_096)
        #expect(try ai.sentMessages() == [["system", Prompts.defaultSystem], ["user", "hello"]])
    }

    @Test func sendsTheKeyAsABearerTokenAndKeepsAFullAddress() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.useServer(address: "https://models.example.test/v1/chat/completions", model: "big")
        try await ai.fakes.secrets.setSecret("server-test-key", for: "ai." + AISecrets.serverKey)
        let url = try #require(URL(string: "https://models.example.test/v1/chat/completions"))
        ai.fakes.http.stub(url, chunks: CompletionSSE.answer(["Hi."]))
        try await ai.harness.run("ask", arguments: ["prompt": "hello"])
        #expect(ai.fakes.http.requests.first?.headers["authorization"] == "Bearer server-test-key")
        #expect(ai.shownText.hasSuffix("Hi."))
    }

    @Test func followUpsSendTheConversationSoFar() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer(CompletionSSE.answer(["One."]))
        try await ai.harness.run("ask", arguments: ["prompt": "first"])
        ai.stubServer(CompletionSSE.answer(["Two."]))
        try await ai.harness.followUp("second")
        #expect(
            try ai.sentMessages(1) == [
                ["system", Prompts.defaultSystem], ["user", "first"], ["assistant", "One."], ["user", "second"],
            ])
    }

    @Test func aCharacterSplitAcrossChunksArrivesWhole() async throws {
        let text = "naïve café 😀"
        let body = Data(CompletionSSE.answer([text]).joined().utf8)
        var chunks: [Data] = []
        var start = body.startIndex
        for index in body.indices where body[index] >= 0xC0 {
            chunks.append(body[start...index])
            start = index + 1
        }
        chunks.append(body[start...])
        let provider = OpenAICompatibleProvider(
            http: ByteChunkHTTP(status: 200, chunks: chunks),
            baseAddress: try #require(URL(string: "http://localhost:1234/v1")),
            apiKey: nil, model: "m")
        var received = ""
        for try await event in provider.stream(ModelRequest(system: "", turns: [ModelTurn(.user, "q")], length: .short))
        {
            if case .text(let piece) = event { received += piece }
        }
        #expect(received == text)
    }

    @Test func aStreamWithoutAnEndWasCutOff() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer([
            CompletionSSE.chunk(content: "Partial"), String(CompletionSSE.chunk(content: "gone").prefix(30)),
        ])
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.hasPrefix("> q\n\nPartial\n\n**Answer Cut Off**"))
    }

    @Test func aFinishReasonWithoutDoneStillFinishes() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer([CompletionSSE.chunk(content: "Done"), CompletionSSE.chunk(content: nil, finishReason: "stop")])
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText == "> q\n\nDone")
    }

    @Test func lengthLimitEndsWithANote() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer(CompletionSSE.answer(["Cut"], finishReason: "length"))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Answer Reached the Length Limit**"))
    }

    @Test func errorsSayWhatToDo() async throws {
        let cases: [(Int, String, String)] = [
            (
                401, "{\"error\":{\"message\":\"Incorrect API key provided\",\"type\":\"invalid_request_error\"}}",
                "API Key Not Accepted"
            ),
            (
                404,
                "{\"error\":{\"message\":\"model \\\"x\\\" not found, try pulling it first\",\"type\":\"api_error\"}}",
                "Model or Address Not Found"
            ),
            (429, "{\"error\":{\"message\":\"Rate limit reached\"}}", "Rate Limited"),
            (503, "Service Unavailable", "localhost Is Busy"),
            (500, "{\"error\":\"model runner crashed\"}", "localhost Had a Problem"),
            (400, "{\"error\":\"bad request\"}", "Request Not Accepted"),
        ]
        for (status, body, title) in cases {
            let ai = try await AIHarness(provider: .openAICompatible)
            ai.stubServer([body], status: status)
            try await ai.harness.run("ask", arguments: ["prompt": "q"])
            #expect(ai.shownText.contains("**\(title)**"), "status \(status)")
        }
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer(["{\"error\":{\"message\":\"model \\\"x\\\" not found\"}}"], status: 404)
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("It said: model \"x\" not found"))
    }

    @Test func anErrorInsideTheStream() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.stubServer([CompletionSSE.chunk(content: "Some"), "data: {\"error\":{\"message\":\"out of memory\"}}\n\n"])
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("Some\n\n**localhost Had a Problem**"))
        #expect(ai.shownText.contains("It said: out of memory"))
    }

    @Test func aServerThatIsNotRunning() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        ai.fakes.http.stub(AIHarness.serverURL) { _ in .failure(URLError(.cannotConnectToHost)) }
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Cannot Reach localhost**\n\nCheck that the server is running"))
    }

    @Test func addressesAreCheckedBeforeUse() {
        #expect(OpenAICompatibleProvider.parseAddress(" http://localhost:11434/v1 ") != nil)
        #expect(OpenAICompatibleProvider.parseAddress("https://api.example.test/v1") != nil)
        #expect(OpenAICompatibleProvider.parseAddress("localhost:11434") == nil)
        #expect(OpenAICompatibleProvider.parseAddress("ftp://example.test") == nil)
        #expect(OpenAICompatibleProvider.parseAddress("https://user:secret@example.test/v1") == nil)
        #expect(OpenAICompatibleProvider.parseAddress("") == nil)
    }
}
