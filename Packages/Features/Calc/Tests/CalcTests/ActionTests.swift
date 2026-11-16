import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// Every action of an answer row and a history row, against the fakes.
@Suite("Actions", .timeLimit(.minutes(1)))
struct ActionTests {
    @Test func anAnswerOffersTheExpectedActionsInOrder() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("0xff"))
        let actions = harness.rootActions(for: row)
        #expect(
            actions.map(\.id) == [
                "copy", "paste", "copy-plain-number", "copy-question-and-answer", "large-type", "copy-form-0",
                "copy-form-1", "run.cmd:calculator.history",
            ])
        #expect(
            actions.map(\.title) == [
                "Copy Answer", "Paste Answer", "Copy as Plain Number", "Copy Question and Answer",
                "Show in Large Type", "Copy Hex", "Copy Binary", "Open Calculator History",
            ])
        #expect(actions.primary?.id == "copy")
        #expect(actions.secondary?.id == "paste")
        #expect(actions[2].shortcut == KeyCombo(.c, [.option, .command]))
        #expect(actions[3].shortcut == KeyCombo(.c, [.option, .shift, .command]))
        #expect(actions[4].shortcut == .largeType)
        #expect(actions[5].section == "Other Forms")
        #expect(actions[1].requires == [.accessibility])
        #expect(harness.issues.isEmpty)
    }

    @Test func copyAnswerCopiesWhatTheRowShowsAndShowsAHUD() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("1234567 * 2"))
        let outcome = try await harness.performRoot("copy", on: row, query: "1234567 * 2")
        #expect(outcome.kind == .close(hud: "Copied 2,469,134"))
        #expect(harness.fakes.pasteboard.copiedTexts == ["2,469,134"])
        #expect(harness.huds.map(\.title) == ["Copied 2,469,134"])
    }

    @Test func copyAsPlainNumberAndQuestionAndAnswer() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("1234567 * 2"))
        try await harness.performRoot("copy-plain-number", on: row, query: "1234567 * 2")
        try await harness.performRoot("copy-question-and-answer", on: row, query: "1234567 * 2")
        let hex = try #require(harness.answerRow("0xff"))
        try await harness.performRoot("copy-form-0", on: hex, query: "0xff")
        #expect(harness.fakes.pasteboard.copiedTexts == ["2469134", "1234567 * 2 = 2,469,134", "0xFF"])
        #expect(harness.huds.map(\.title) == ["Copied 2469134", "Copied Question and Answer", "Copied 0xFF"])
    }

    @Test func pasteNeedsAccessibilityAndAsksOnlyThroughTheHost() async throws {
        let fakes = FakeServices(permissions: .denied)
        let harness = await readyHarness(fakes: fakes)
        let row = try #require(harness.answerRow("6 * 7"))
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await harness.performRoot("paste", on: row, query: "6 * 7")
        }
        #expect(fakes.permissions.requests.isEmpty, "nothing prompts until the user presses Grant")
        #expect(fakes.pasteboard.pastedTexts.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.performRoot("paste", on: row, query: "6 * 7")
        #expect(fakes.pasteboard.pastedTexts == ["42"])
    }

    @Test func openCalculatorHistoryPushesTheHistory() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("6 * 7"))
        try await harness.performRoot("copy", on: row, query: "6 * 7")
        try await harness.performRoot("run.cmd:calculator.history", on: row, query: "6 * 7")
        #expect(harness.commandRuns.map(\.id) == [ItemID.command(feature: "calculator", command: "history")])
        #expect(harness.rows.map(\.title) == ["42"])
        harness.unavailableCommands = [ItemID.command(feature: "calculator", command: "history")]
        #expect(!harness.rootActions(for: row).map(\.id).contains("run.cmd:calculator.history"))
    }

    @Test func historyRowActions() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("1500 * 2"))
        try await harness.performRoot("copy", on: row, query: "1500 * 2")
        try await harness.run("history")
        #expect(
            harness.actions().map(\.title) == [
                "Copy Answer", "Use Again", "Paste Answer", "Copy as Plain Number", "Copy Question and Answer",
                "Delete Answer", "Clear History",
            ])
        try await harness.perform("copy-plain-number")
        try await harness.run("history")
        try await harness.perform("copy-question-and-answer")
        try await harness.run("history")
        try await harness.performPrimary()
        try await harness.run("history")
        try await harness.perform("paste")
        #expect(
            harness.fakes.pasteboard.copiedTexts == ["3,000", "3000", "1500 * 2 = 3,000", "3,000", "3,000"],
            "\(harness.fakes.pasteboard.copiedTexts)")
        #expect(harness.fakes.pasteboard.pastedTexts == ["3,000"])
        let destructive = harness.actions().filter { $0.style == .destructive }
        #expect(destructive.allSatisfy { $0.confirmation?.isDestructive == true })
        #expect(harness.issues.isEmpty)
    }

    @Test func answerActionsWorkFromARowRebuiltFromJSON() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("6 * 7"))
        let rebuilt = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        #expect(harness.rootActions(for: rebuilt).map(\.id) == harness.rootActions(for: row).map(\.id))
        try await harness.performRoot("copy", on: rebuilt, query: "6 * 7")
        #expect(harness.fakes.pasteboard.copiedTexts == ["42"])
    }

    @Test func aLongAnswerIsShortenedInTheHUD() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("123456789 in words"))
        try await harness.performRoot("copy", on: row, query: "123456789 in words")
        let hud = try #require(harness.huds.first?.title)
        #expect(hud.hasSuffix("…") && hud.count <= "Copied ".count + 40)
        #expect(harness.fakes.pasteboard.copiedTexts.first?.hasSuffix("eighty-nine") == true)
    }
}
