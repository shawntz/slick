import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import AI

/// What a second review found: what leaves the Mac, deletions that must ask, requests nobody asked
/// for, odd files, very long text and many commands.
@Suite("Hardening", .timeLimit(.minutes(1)))
@MainActor
struct HardeningTests {
    private func footer(_ ai: AIHarness) -> String {
        ai.feature.settingsPane?.sections.first?.footer ?? ""
    }

    private func commandsURL(_ ai: AIHarness) throws -> URL {
        let url = ai.harness.context.storage.dataFile(AIFeature.commandsFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    // MARK: - What leaves the Mac

    @Test func theFooterNamesClipboardTextAndAnUnencryptedAddress() async throws {
        let ai = try await AIHarness()
        #expect(footer(ai).contains("clipboard text"))
        #expect(!footer(ai).contains("unencrypted"))

        try await ai.useAnthropic()
        try await ai.harness.settle()
        #expect(footer(ai).contains("the clipboard text when one of your own commands uses it"))
        #expect(!footer(ai).contains("unencrypted"))

        for local in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
            ai.useServer(address: local)
            try await ai.harness.settle()
            #expect(!footer(ai).contains("unencrypted"), "\(local) stays on this Mac")
        }
        ai.useServer(address: "https://models.example.com/v1")
        try await ai.harness.settle()
        #expect(!footer(ai).contains("unencrypted"))

        ai.useServer(address: "http://models.example.com:8080/v1")
        try await ai.harness.settle()
        #expect(footer(ai).contains("to models.example.com, and nowhere else"))
        #expect(footer(ai).contains("plain http, so all of it, the key included, crosses the network unencrypted"))
    }

    @Test func aCommandThatUsesTheClipboardSendsItOnlyWhenRun() async throws {
        let ai = try await AIHarness()
        try await ai.feature.saveCustomCommands([
            CustomCommand(
                id: "custom.clip-0000eeee", title: "Explain Clipboard", prompt: "Explain {clipboard}",
                replacesSelection: false)
        ])
        _ = ai.fakes.pasteboard.simulateCopy("copied words")
        try await ai.harness.settle()
        #expect(ai.onDevice.requests.isEmpty)
        try await ai.harness.run("custom.clip-0000eeee")
        #expect(ai.onDevice.requests.last?.prompt == "Explain \"\"\"copied words\"\"\"")
    }

    // MARK: - Deleting chats

    @Test func aShorterTimeToKeepChatsAsksFirst() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("new-chat")
        try await ai.harness.followUp("an old chat")
        ai.harness.pop()
        ai.fakes.clock.advance(by: .seconds(10 * 86_400))

        ai.harness.confirmationAnswer = false
        #expect(try ai.harness.chooseSetting("Keep chats", option: "For 1 week") == false)
        #expect(ai.harness.confirmations.last?.title == "Delete Older Chats?")
        #expect(ai.harness.confirmations.last?.isDestructive == true)
        try await ai.harness.settle()
        #expect(ai.settings[AISettings.retention] == .forever)
        #expect(try await ai.feature.store.all().count == 1, "declining keeps every chat")

        ai.harness.confirmationAnswer = true
        #expect(try ai.harness.chooseSetting("Keep chats", option: "For 1 week"))
        try await ai.harness.settle()
        #expect(try await ai.feature.store.all().isEmpty)

        let asked = ai.harness.confirmations.count
        #expect(try ai.harness.chooseSetting("Keep chats", option: "For 1 year"))
        #expect(ai.harness.confirmations.count == asked, "a longer time deletes nothing, so it does not ask")
        #expect(try ai.harness.chooseSetting("Keep chats", option: "Until you delete them"))
        #expect(ai.harness.confirmations.count == asked)

        #expect(try ai.harness.chooseSetting("Keep chats", option: "Don't keep chats"))
        #expect(ai.harness.confirmations.last?.title == "Delete All Chats?")
        #expect(ai.harness.confirmations.last?.message?.contains("every kept chat is deleted now") == true)
    }

    // MARK: - Requests nobody asked for

    @Test func aKeptChatThatEndsInAQuestionIsNotSentWhenOpened() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        let now = ai.fakes.clock.now
        var kept = Conversation(created: now, systemPrompt: "Be brief.")
        kept.messages = [
            ChatMessage(role: .user, text: "first", date: now),
            ChatMessage(role: .assistant, text: "First answer.", date: now),
            ChatMessage(role: .user, text: "never answered", date: now),
        ]
        try await ai.feature.store.save(kept)

        try await ai.harness.run("chat")
        try await ai.harness.performPrimary()
        try await ai.harness.settle()
        #expect(ai.fakes.http.requests.isEmpty, "opening a chat sends nothing")
        #expect(ai.shownText.hasSuffix("> never answered\n\n**Not Sent**\n\n" + Strings.Notes.notSentMessage))
        #expect(ai.harness.actions().map(\.id) == ["regenerate"])

        ai.stubAnthropic(AnthropicSSE.answer(["Now answered."]))
        try await ai.harness.perform("regenerate")
        try await eventually { ai.session?.isStreaming == false && ai.fakes.http.requests.count == 1 }
        #expect(try ai.sentMessages().last == ["user", "never answered"])
        #expect(ai.session?.conversation.messages.last?.text == "Now answered.")
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func askAIWithNothingTypedOpensAnEmptyPage() async throws {
        let ai = try await AIHarness()
        #expect(try ai.harness.command("ask").arguments.first?.isOptional == true)
        try await ai.harness.run("ask", query: "", launch: .tabFromRoot)
        #expect(ai.session?.mode == .ask)
        #expect(ai.shownText == Strings.Ask.emptyHint)
        #expect(ai.session?.followUp?.placeholder == "Ask a question")
        #expect(ai.onDevice.requests.isEmpty)
        #expect(ai.harness.actions().isEmpty)

        try await ai.harness.followUp("why is the sky blue")
        #expect(ai.onDevice.requests.last?.prompt == "why is the sky blue")
        #expect(ai.shownText == "> why is the sky blue\n\nOn-device answer.")
        #expect(ai.harness.actions().first?.title == "Copy Answer")

        try await ai.harness.run("ask", arguments: ["prompt": "   "])
        #expect(ai.shownText == Strings.Ask.emptyHint, "white space alone is not a question")
        #expect(ai.onDevice.requests.count == 1)
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func anEmptyAskFromADeepLinkShowsTheForm() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("ask", launch: .deeplink)
        guard case .form = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(ai.onDevice.requests.isEmpty)
    }

    // MARK: - Very long text

    @Test func aFollowUpOverTheLimitIsNotSent() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Short answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "short question"])
        try await eventually { ai.session?.isStreaming == false }
        let messages = ai.session?.conversation.messages.count
        let huge = String(repeating: "ab ", count: TextInput.maximumBytes / 3 + 10)
        try await ai.harness.followUp(huge)
        #expect(ai.fakes.http.requests.count == 1)
        #expect(ai.session?.conversation.messages.count == messages)
        #expect(ai.shownText.hasSuffix("**Text Too Long**\n\nUse less text, then try again."))

        let multibyte = String(repeating: "日", count: TextInput.maximumBytes / 3 + 1)
        try await ai.harness.followUp(multibyte)
        #expect(ai.fakes.http.requests.count == 1, "the limit counts bytes, so wide characters count as more")
    }

    // MARK: - Odd files

    @Test func anUnreadableCommandsFileShowsAStatusAndKeepsTheFile() async throws {
        let ai = try await AIHarness(activate: false)
        let url = try commandsURL(ai)
        try Data([0xFF, 0xFE, 0x00, 0x7B]).write(to: url)
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()
        let status = try #require(ai.feature.status)
        #expect(status.level == .warning)
        #expect(status.title == "AI Commands Could Not Be Read")
        #expect(status.message?.contains("left as it is") == true)
        #expect(ai.feature.customCommands.isEmpty)
        #expect(try Data(contentsOf: url) == Data([0xFF, 0xFE, 0x00, 0x7B]))

        // Fixed while the feature was off: the next activation reads it and the status goes.
        await ai.harness.deactivate()
        try Data(#"{"version": 1, "commands": [{"title": "Fixed", "prompt": "Hi"}]}"#.utf8).write(to: url)
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()
        #expect(ai.feature.status == nil)
        #expect(ai.feature.customCommands.map(\.title) == ["Fixed"])
    }

    @Test func aCommandsFileFromANewerVersionIsUsedButNeverSaved() async throws {
        let ai = try await AIHarness(activate: false)
        let url = try commandsURL(ai)
        let raw =
            #"{"version": 9, "future": true, "commands": [{"id": "custom.a-1", "title": "Later", "prompt": "x"}]}"#
        try Data(raw.utf8).write(to: url)
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()
        #expect(ai.feature.customCommands.map(\.title) == ["Later"])
        #expect(ai.feature.status?.title == "AI Commands Are Read Only")
        await #expect(throws: Strings.Failures.commandsNewer) {
            try await ai.feature.saveCustomCommands([])
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == raw)
    }

    // MARK: - Many commands

    @Test func fiftyThousandCommandsAreParsedOffTheMainThread() async throws {
        let ai = try await AIHarness(activate: false)
        let commands = (0..<50_000).map { index in
            CustomCommand(
                id: "custom.c-\(index)", title: "Command \(index)",
                prompt: index.isMultiple(of: 2)
                    ? "Rewrite {selection} in a {argument name=\"style\"} way, number \(index)"
                    : "Tell me about {argument name=\"topic\"} on {date}, number \(index)",
                replacesSelection: true)
        }
        try await JSONFileStore<CustomCommandFile>(url: try commandsURL(ai)).save(CustomCommandFile(commands: commands))
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()

        // Before the prompts were parsed once at load, each of these parsed all 50,000 prompts on the
        // main thread: about 570 ms and 480 ms in a debug build.
        let clock = ContinuousClock()
        let declaredStart = clock.now
        let declared = ai.feature.commands
        let declaredTime = clock.now - declaredStart
        let universalStart = clock.now
        let universal = ai.harness.universalActions(for: .text("hello"))
        let universalTime = clock.now - universalStart
        #expect(declared.count == 50_000 + 13)
        #expect(universal.count == 25_000 + TextCommandKind.allCases.count)
        #expect(declaredTime < .milliseconds(250), "commands took \(declaredTime)")
        #expect(universalTime < .milliseconds(250), "universal actions took \(universalTime)")
        let first = try ai.harness.command("custom.c-0")
        #expect(first.arguments.map(\.name) == ["style"])
    }

    // MARK: - Off and on

    @Test func switchingOffAndOnReadsTheCommandsAgainAndSendsNothing() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        try await ai.feature.saveCustomCommands([
            CustomCommand(id: "custom.one-1", title: "One", prompt: "One", replacesSelection: false)
        ])
        for _ in 0..<3 {
            await ai.harness.deactivate()
            await ai.harness.activate()
            await ai.feature.waitUntilLoaded()
        }
        #expect(ai.feature.customCommands.map(\.title) == ["One"])
        #expect(ai.fakes.http.requests.isEmpty)
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.fakes.permissions.openStreamCount == 0)
    }
}
