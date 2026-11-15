import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("Commands on text", .timeLimit(.minutes(1)))
@MainActor
struct TextCommandTests {
    @Test func everyCommandIsDeclared() async throws {
        let ai = try await AIHarness()
        let titles = TextCommandKind.allCases.map { try? ai.harness.command($0.rawValue).title }
        #expect(
            titles == [
                "Improve Writing", "Fix Spelling and Grammar", "Make Shorter", "Make Longer", "Change Tone",
                "Summarize", "Explain", "Translate",
            ])
        #expect(try ai.harness.command("change-tone").arguments.first?.defaultValue == "professional")
        #expect(try ai.harness.command("translate").arguments.first?.isOptional == true)
        #expect(try ai.harness.command("summarize").keywords.contains("summarise"))
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func improveWritingRewritesTheSelectionAndReplacesIt() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.fakes.selection.selection = .text("teh quick brown fox")
        ai.stubAnthropic(AnthropicSSE.answer(["The quick brown fox.\n"]))
        try await ai.harness.run("improve-writing")

        let sent = try #require(try ai.sentMessages().first?.last)
        #expect(sent.hasPrefix("Improve the writing of the text below."))
        #expect(sent.hasSuffix("Text:\n\"\"\"\nteh quick brown fox\n\"\"\""))
        #expect(ai.shownText == "The quick brown fox.\n", "the prompt is not shown")
        #expect(
            ai.harness.page.map { page -> String? in
                if case .detail(let detail) = page.page { return detail.title }
                return nil
            } == "Improve Writing")
        #expect(ai.harness.actions().map(\.title).prefix(2) == ["Replace Selection", "Copy Result"])

        try await ai.harness.performPrimary()
        #expect(ai.fakes.pasteboard.pastedTexts == ["The quick brown fox."])
        #expect(ai.harness.isClosed)
    }

    @Test func summariesAreCopiedFirst() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = .text("A long article.")
        try await ai.harness.run("summarize")
        #expect(ai.harness.actions().map(\.title).prefix(2) == ["Copy Result", "Replace Selection"])
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Summarize the text below") == true)
    }

    @Test func withoutAccessibilityTheHostAsksFirstAndNothingIsRead() async throws {
        let ai = try await AIHarness(permissions: .notDetermined)
        ai.fakes.selection.selection = .text("secret")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await ai.harness.run("fix-spelling-and-grammar")
        }
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.fakes.permissions.requests.isEmpty)

        ai.harness.grantsMissingPermissions = true
        try await ai.harness.run("fix-spelling-and-grammar")
        #expect(ai.fakes.permissions.requests == [.accessibility])
        #expect(ai.onDevice.requests.last?.prompt.contains("secret") == true)
    }

    @Test func nothingSelectedSaysSo() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = nil
        try await ai.harness.run("make-shorter")
        #expect(ai.harness.toasts.last?.title == "No Text Selected")
        #expect(ai.onDevice.requests.isEmpty)

        ai.fakes.selection.selection = .text("   \n ")
        try await ai.harness.run("make-shorter")
        #expect(ai.onDevice.requests.isEmpty)

        ai.fakes.selection.selection = .files([URL(filePath: "/tmp/example.txt")])
        try await ai.harness.run("make-shorter")
        #expect(ai.onDevice.requests.isEmpty)
    }

    @Test func tooMuchTextIsRefused() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = .text(String(repeating: "a", count: TextInput.maximumBytes + 1))
        await #expect(throws: Strings.Failures.textTooLong) { try await ai.harness.run("make-longer") }
        #expect(ai.onDevice.requests.isEmpty)
    }

    @Test func changeToneAndTranslateUseTheirArguments() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = .text("hey, send it")
        try await ai.harness.run("change-tone", arguments: ["tone": "friendly"])
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Rewrite the text below in a friendly tone.") == true)

        try await ai.harness.run("translate")
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Translate the text below into English.") == true)
        ai.settings[AISettings.translateLanguage] = "German"
        try await ai.harness.run("translate")
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Translate the text below into German.") == true)
        try await ai.harness.run("translate", arguments: ["language": "Japanese"])
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Translate the text below into Japanese.") == true)
    }

    @Test func universalActionsWorkOnTheGivenText() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = .text("not this")
        let actions = ai.harness.universalActions(for: .text("given text"))
        #expect(
            actions.map(\.title) == [
                "Improve Writing", "Fix Spelling and Grammar", "Make Shorter", "Make Longer", "Change Tone",
                "Summarize", "Explain", "Translate into English",
            ])
        #expect(actions.allSatisfy { $0.section == "AI" })

        try await ai.harness.performUniversal("explain", on: .text("given text"))
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.onDevice.requests.last?.prompt.contains("given text") == true)
        #expect(ai.harness.actions().first?.title == "Copy Result")

        try await ai.harness.performUniversal("improve-writing", on: .text("given text"))
        #expect(ai.harness.actions().first?.title == "Replace Selection")

        let tones = try await ai.harness.submenu("change-tone", in: actions, row: nil)
        #expect(tones.map(\.title) == ["Professional", "Friendly", "Casual", "Confident"])
        try await ai.harness.perform(try #require(tones.last), row: nil, query: "given text", launch: .selection)
        #expect(ai.onDevice.requests.last?.prompt.hasPrefix("Rewrite the text below in a confident tone.") == true)
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func aRowsTextIsPastedNotReplaced() async throws {
        let ai = try await AIHarness()
        let row = Row(id: ItemID("clipboard", "1"), title: "Copied text", represents: .text("from a list"))
        let actions = ai.harness.universalActions(for: row)
        try await ai.harness.perform(try #require(actions.first), row: row, query: "from a list", launch: .page)
        #expect(ai.harness.actions().map(\.title).prefix(2) == ["Copy Result", "Paste Result"])
    }

    @Test func continueInChatTitlesTheChatByCommandAndText() async throws {
        let ai = try await AIHarness()
        ai.fakes.selection.selection = .text("the meeting moved to Friday")
        try await ai.harness.run("improve-writing")
        try await ai.harness.perform("Continue in Chat")
        #expect(ai.session?.pageTitle == "Improve Writing: the meeting moved to Friday")
        #expect(ai.shownText.hasPrefix("> Improve Writing\n\nOn-device answer."))
    }
}
