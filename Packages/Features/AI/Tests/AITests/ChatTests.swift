import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import AI

@Suite("AI Chat", .timeLimit(.minutes(1)))
@MainActor
struct ChatTests {
    /// Starts a chat with one question and its answer, then goes back to root.
    private func chat(_ ai: AIHarness, question: String, answer: [String] = ["On-device ", "answer."]) async throws {
        ai.onDevice.pieces = answer
        try await ai.harness.run("new-chat")
        #expect(ai.shownText == "Type a message and press Return to start.")
        #expect(ai.harness.actions().isEmpty)
        try await ai.harness.followUp(question)
        ai.harness.pop()
    }

    @Test func aNewChatIsSavedAfterItsFirstAnswer() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("new-chat")
        try await ai.harness.followUp("plan a trip")
        #expect(ai.shownText == "> plan a trip\n\nOn-device answer.")
        let stored = try await ai.feature.store.all()
        #expect(stored.count == 1)
        #expect(stored.first?.displayTitle == "plan a trip")
        #expect(stored.first?.systemPrompt == Prompts.defaultSystem)
        let file = ai.feature.store.folder.appending(path: try #require(stored.first?.id) + ".json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(modified == stored.first?.updated)
    }

    @Test func theListShowsChatsByDayAndOpensThem() async throws {
        let ai = try await AIHarness()
        try await chat(ai, question: "older question")
        ai.fakes.clock.advance(by: .seconds(86_400))
        try await chat(ai, question: "newer question", answer: ["Newer answer."])

        try await ai.harness.run("chat")
        #expect(ai.harness.sections.map(\.title) == ["Today", "Yesterday"])
        #expect(ai.harness.rows.map(\.title) == ["newer question", "older question"])
        #expect(ai.harness.rows.first?.subtitle == "Newer answer.")
        let preview = try await ai.harness.loadDetail()
        #expect(preview?.body == .markdown("> newer question\n\nNewer answer."))

        try await ai.harness.setQuery("older")
        #expect(ai.harness.rows.map(\.title) == ["older question"])
        try await ai.harness.performPrimary()
        #expect(ai.session?.mode == .chat)
        #expect(ai.shownText == "> older question\n\nOn-device answer.")

        ai.onDevice.pieces = ["Follow-up answer."]
        try await ai.harness.followUp("and then?")
        let prompt = try #require(ai.onDevice.requests.last?.prompt)
        #expect(prompt.contains("User: older question"))
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func renameExportAndDelete() async throws {
        let ai = try await AIHarness()
        try await chat(ai, question: "first chat")
        try await chat(ai, question: "second chat")
        try await ai.harness.run("chat")
        try ai.harness.select(title: "first chat")
        #expect(
            ai.harness.actions().map(\.title) == [
                "Open Chat", "New Chat", "Rename Chat", "Export as Markdown", "Delete Chat", "Delete All Chats",
            ])

        try await ai.harness.perform("Rename Chat")
        try ai.harness.fill("title", text: "Renamed\nChat")
        try await ai.harness.submit()
        #expect(ai.harness.rows.map(\.title).contains("Renamed Chat"))

        let export = ai.fakes.storage.root.appending(path: "exported.md")
        ai.fakes.fileDialogs.saveLocation = export
        try ai.harness.select(title: "Renamed Chat")
        try await ai.harness.perform("Export as Markdown")
        #expect(ai.fakes.fileDialogs.saveRequests.last?.suggestedName == "Renamed Chat.md")
        let markdown = try String(contentsOf: export, encoding: .utf8)
        #expect(markdown.hasPrefix("# Renamed Chat\n\nStarted "))
        #expect(markdown.contains("## You\n\nfirst chat\n"))
        #expect(markdown.contains("## Assistant (Apple On-Device Model)\n\nOn-device answer.\n"))
        #expect(ai.harness.toasts.last?.title == "Exported Chat")

        ai.harness.confirmationAnswer = false
        try await ai.harness.perform("Delete Chat")
        #expect(ai.harness.rows.count == 2)
        ai.harness.confirmationAnswer = true
        try await ai.harness.perform("Delete Chat")
        #expect(ai.harness.confirmations.last?.title == "Delete \u{201C}Renamed Chat\u{201D}?")
        #expect(ai.harness.rows.map(\.title) == ["second chat"])

        try await ai.harness.perform("Delete All Chats")
        #expect(ai.harness.rows.isEmpty)
        #expect(ai.harness.page?.emptyState?.title == "No Chats")
        #expect(ai.harness.toasts.last?.title == "Deleted 1 Chat")
    }

    @Test func oldChatsAreDeletedAfterTheChosenTime() async throws {
        let ai = try await AIHarness()
        ai.settings[AISettings.retention] = .week
        try await ai.harness.settle()
        try await chat(ai, question: "old")
        ai.fakes.clock.advance(by: .seconds(6 * 86_400))
        try await chat(ai, question: "recent")
        ai.fakes.clock.advance(by: .seconds(2 * 86_400))

        try await ai.harness.run("chat")
        #expect(ai.harness.rows.map(\.title) == ["recent"])
        #expect(try await ai.feature.store.all().count == 1)

        ai.settings[AISettings.retention] = .day
        try await ai.harness.settle()
        #expect(ai.harness.rows.isEmpty)
    }

    @Test func keepingNoChatsWritesNothingAndDeletesWhatWasKept() async throws {
        let ai = try await AIHarness()
        try await chat(ai, question: "kept for now")
        #expect(try await ai.feature.store.all().count == 1)

        ai.settings[AISettings.retention] = .none
        try await ai.harness.settle()
        #expect(try await ai.feature.store.all().isEmpty)

        try await chat(ai, question: "not kept")
        #expect(try await ai.feature.store.all().isEmpty)
        try await ai.harness.run("chat")
        #expect(ai.harness.page?.emptyState?.message == Strings.Chat.notKeptMessage)
    }

    @Test func aDamagedFileIsSkipped() async throws {
        let ai = try await AIHarness()
        try await chat(ai, question: "good chat")
        try Data("not json".utf8).write(to: ai.feature.store.folder.appending(path: "0000-damaged.json"))
        let fresh = ConversationStore(folder: ai.feature.store.folder)
        #expect(try await fresh.all().map(\.displayTitle) == ["good chat"])
    }

    @Test func aChatFromANewerVersionIsNotOverwritten() async throws {
        let fakes = FakeServices()
        let store = ConversationStore(folder: fakes.context(featureID: "ai").storage.dataDirectory)
        var conversation = Conversation(created: Date(timeIntervalSince1970: 1_763_000_000), systemPrompt: "")
        conversation.version = Conversation.currentVersion + 1
        await #expect(throws: Strings.Failures.newerChat) { try await store.save(conversation) }
    }

    @Test func idsThatAreNotSafeFileNamesAreRefused() {
        #expect(ConversationStore.isValidID("0a1b2c3d-0000-4000-8000-000000000000"))
        #expect(!ConversationStore.isValidID("../escape"))
        #expect(!ConversationStore.isValidID("a/b"))
        #expect(!ConversationStore.isValidID(""))
    }

    @Test func theChatListFollowsChangesToTheStore() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("chat")
        #expect(ai.harness.rows.isEmpty)
        var conversation = ai.feature.services.newConversation()
        conversation.messages = [ChatMessage(role: .user, text: "added elsewhere", date: ai.fakes.clock.now)]
        try await ai.feature.store.save(conversation)
        try await ai.harness.waitForChange()
        #expect(ai.harness.rows.map(\.title) == ["added elsewhere"])
    }

    @Test func leavingAChatWhileItAnswersStillSavesWhatArrived() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(
            [AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0), AnthropicSSE.textDelta("Half", index: 0)],
            keepsOpen: true)
        do {
            var conversation = ai.feature.services.newConversation()
            conversation.messages = [ChatMessage(role: .user, text: "long question", date: ai.fakes.clock.now)]
            let session = AnswerSession(
                conversation: conversation, mode: .chat, title: "Chat", services: ai.feature.services)
            var iterator = session.start().makeAsyncIterator()
            var detail = Detail()
            while let update = try await iterator.next() {
                detail.apply(update)
                if case .markdown(let text) = detail.body, text.hasSuffix("Half") { break }
            }
            // The page goes away: the host drops the stream and the source.
        }
        var stored: [Conversation] = []
        for _ in 0..<200 where stored.isEmpty {
            stored = try await ai.feature.store.all()
            if stored.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(stored.first?.messages.last?.text == "Half")
        #expect(stored.first?.messages.last?.ending == .stopped)
    }

    @Test func newChatFromTheListSetsUpAProviderFirst() async throws {
        let ai = try await AIHarness(onDeviceStatus: .notReady)
        try await ai.harness.run("chat")
        #expect(ai.harness.page?.emptyState?.title == "No Chats")
        try await ai.harness.perform("New Chat")
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected the setup form")
            return
        }
        #expect(form.title == "Set Up AI")
    }
}
