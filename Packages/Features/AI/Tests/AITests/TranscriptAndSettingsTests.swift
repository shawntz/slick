import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("Transcripts", .timeLimit(.minutes(1)))
struct TranscriptTests {
    @Test func theLastClosedCodeBlockIsFound() {
        #expect(Transcript.lastCodeBlock(in: "No code here.") == nil)
        #expect(Transcript.lastCodeBlock(in: "```\nfirst\n```\ntext\n```python\nsecond\nline\n```") == "second\nline")
        #expect(Transcript.lastCodeBlock(in: "```\nclosed\n```\n```\nnever closed") == "closed")
        #expect(Transcript.lastCodeBlock(in: "````\nouter ``` inner\n```\n````") == "outer ``` inner\n```")
        #expect(Transcript.lastCodeBlock(in: "~~~\ntilde\n~~~") == "tilde")
        #expect(Transcript.lastCodeBlock(in: "```\r\nwindows\r\n```\r\n") == "windows")
        #expect(Transcript.lastCodeBlock(in: "    ```\nindented four is not a fence\n    ```") == nil)
        #expect(Transcript.lastCodeBlock(in: "```\n```") == "")
    }

    @Test func titlesAreOneShortLine() {
        #expect(Transcript.title(from: "\n\n  what is\tglass  \nsecond line") == "what is glass")
        #expect(Transcript.title(from: "") == "New Chat")
        #expect(Transcript.title(from: String(repeating: "word ", count: 40)).count == 60)
        #expect(Transcript.title(from: "a\u{202E}b\u{0}c") == "a b c")
        #expect(Transcript.oneLine("First\nLine", limit: 80) == "First Line")
    }

    @Test func renderingQuotesQuestionsAndNotesEndings() {
        let date = Date(timeIntervalSince1970: 1_763_000_000)
        let messages = [
            ChatMessage(role: .user, text: "line one\nline two", date: date),
            ChatMessage(role: .assistant, text: "Answer.", date: date),
            ChatMessage(role: .user, text: "next", date: date),
            ChatMessage(role: .assistant, text: "Part", date: date, ending: .stopped),
        ]
        #expect(
            Transcript.render(messages)
                == "> line one\n> line two\n\nAnswer.\n\n---\n\n> next\n\nPart\n\n**Stopped**")
        #expect(Transcript.render(messages, hidesFirstQuestion: true).hasPrefix("Answer.\n\n---"))
    }

    @Test func exportFileNamesAreSafe() {
        var conversation = Conversation(created: Date(timeIntervalSince1970: 0), systemPrompt: "")
        conversation.title = "a/b: c?"
        #expect(Transcript.fileName(for: conversation) == "a-b- c.md")
        conversation.title = "..."
        #expect(Transcript.fileName(for: conversation) == "New Chat.md")
    }

    @Test func retryAfterIsReadInAnyCase() {
        #expect(HTTPFailures.retryAfterSeconds(["retry-after": "3"]) == 3)
        #expect(HTTPFailures.retryAfterSeconds(["Retry-After": "2.5"]) == 3)
        #expect(HTTPFailures.retryAfterSeconds(["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]) == nil)
        #expect(HTTPFailures.retryAfterSeconds([:]) == nil)
    }

    @Test func transportErrorsGetWords() {
        func title(_ code: URLError.Code) -> String? {
            (HTTPFailures.transport(URLError(code), host: "example.test") as? AIFailure)?.title
        }
        #expect(title(.notConnectedToInternet) == "No Internet Connection")
        #expect(title(.networkConnectionLost) == "No Internet Connection")
        #expect(title(.cannotFindHost) == "Cannot Find example.test")
        #expect(title(.timedOut) == "example.test Did Not Answer")
        #expect(title(.serverCertificateUntrusted) == "Secure Connection Failed")
        #expect(title(.appTransportSecurityRequiresSecureConnection) == "Address Needs HTTPS")
        #expect(HTTPFailures.transport(URLError(.cancelled), host: "x") is CancellationError)
        #expect(HTTPFailures.transport(CancellationError(), host: "x") is CancellationError)
    }
}

@Suite("Settings", .timeLimit(.minutes(1)))
@MainActor
struct SettingsTests {
    private func footer(_ ai: AIHarness) -> String {
        ai.feature.settingsPane?.sections.first?.footer ?? ""
    }

    @Test func thePaneSaysWhatIsSentAndWhere() async throws {
        let ai = try await AIHarness()
        #expect(footer(ai).contains("stay on this Mac"))

        let changes = try #require(ai.feature.declarationChanges)
        let before = changes.generation
        try await ai.useAnthropic()
        try await ai.harness.settle()
        #expect(changes.generation > before)
        #expect(footer(ai).contains("to api.anthropic.com, and nowhere else"))
        #expect(footer(ai).contains("the selected text when a command uses it"))
        #expect(footer(ai).contains("the system prompt and the response length"))
        #expect(footer(ai).contains(Brand.name))

        ai.useServer(address: "http://localhost:1234/v1")
        try await ai.harness.settle()
        #expect(footer(ai).contains("to localhost, and nowhere else"))
    }

    @Test func thePaneHasTheExpectedChoices() async throws {
        let ai = try await AIHarness()
        let pane = try #require(ai.feature.settingsPane)
        #expect(
            pane.sections.map(\.title) == [
                "Provider", "Anthropic", "OpenAI-Compatible Server", "Answers", "Chat History", "Permissions",
            ])
        let items = pane.sections.flatMap(\.items)
        let secrets = items.compactMap { item -> String? in
            if case .secret(let name, _) = item.control { return name }
            return nil
        }
        #expect(secrets == ["anthropicKey", "serverKey"])
        #expect(items.compactMap(\.control.key?.name).contains("chatRetention"))
        let storage = pane.sections.first { $0.title == "Chat History" }?.footer ?? ""
        #expect(storage.contains("/Chats"))
        #expect(storage.contains("commands.json"))
        // The folder joins each name with one "/", never two.
        #expect(!storage.contains("//"), "\(storage)")
    }

    @Test func theDefaultsAreSafe() {
        #expect(AISettings.provider.defaultValue == .onDevice)
        #expect(AISettings.anthropicModel.defaultValue == .opus)
        #expect(AISettings.serverAddress.defaultValue.isEmpty)
        #expect(AISettings.retention.defaultValue == .forever)
        #expect(AIFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(AIFeature.manifest.permissions.first?.reason.hasPrefix("Read") == true)
    }

    @Test func deleteAllChatsAsksFirst() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("new-chat")
        try await ai.harness.followUp("to delete")
        ai.harness.confirmationAnswer = false
        try await ai.harness.pressSettingsButton("Delete All Chats")
        #expect(try await ai.feature.store.all().count == 1)
        ai.harness.confirmationAnswer = true
        try await ai.harness.pressSettingsButton("Delete All Chats")
        #expect(try await ai.feature.store.all().isEmpty)
        #expect(ai.harness.toasts.last?.title == "Deleted 1 Chat")
    }

    @Test func aNewSystemPromptAppliesToNewQuestions() async throws {
        let ai = try await AIHarness()
        ai.settings[AISettings.systemPrompt] = "Answer like a pirate."
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.onDevice.requests.last?.instructions == "Answer like a pirate.")
    }
}
