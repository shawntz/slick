import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// The history of copied and pasted answers, on the fake clock.
@Suite("History", .timeLimit(.minutes(1)))
struct HistoryTests {
    /// Copies the answer to a query as Return does in root search.
    private func copy(_ query: String, in harness: FeatureHarness<CalculatorFeature>) async throws {
        let row = try #require(harness.answerRow(query), "no answer for \(query)")
        try await harness.performRoot("copy", on: row, query: query)
    }

    @Test func copiedAnswersAreListedByDayNewestFirst() async throws {
        let harness = await readyHarness()
        try await copy("2 + 2", in: harness)
        harness.fakes.clock.advance(by: .seconds(3600))
        try await copy("12 * 3", in: harness)
        harness.fakes.clock.advance(by: .seconds(24 * 3600))
        try await copy("10 kg in lbs", in: harness)
        try await harness.run("history")
        #expect(harness.sections.map(\.title) == ["Today", "Yesterday"])
        #expect(harness.sections[0].rows.map(\.title) == ["22.0462 lb"])
        #expect(harness.sections[1].rows.map(\.title) == ["36", "4"])
        #expect(harness.sections[1].rows.map(\.subtitle) == ["12 * 3", "2 + 2"])
        try await harness.setQuery("kg")
        #expect(harness.rows.map(\.title) == ["22.0462 lb"], "the question is searchable")
        #expect(harness.issues.isEmpty)
    }

    @Test func theSameQuestionMovesToTheTopAndTheFileHoldsIt() async throws {
        let fakes = FakeServices()
        let harness = await readyHarness(fakes: fakes)
        try await copy("2 + 2", in: harness)
        try await copy("3 + 3", in: harness)
        harness.fakes.clock.advance(by: .seconds(60))
        try await copy("  2 + 2", in: harness)
        #expect(harness.feature.history.entries.map(\.question) == ["2 + 2", "3 + 3"])
        let file = fakes.storage.dataDirectory(for: "calculator").appending(path: "history.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"question\" : \"3 + 3\""))

        // A new launch over the same folder reads it back.
        let next = await readyHarness(fakes: fakes)
        #expect(next.feature.history.entries.map(\.question) == ["2 + 2", "3 + 3"])
    }

    @Test func pastingAndTheOtherCopiesRecordTooButOtherFormsDoNot() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("0xff + 1"))
        try await harness.performRoot("paste", on: row, query: "0xff + 1")
        #expect(harness.fakes.pasteboard.pastedTexts == ["256"])
        let other = try #require(harness.answerRow("5 * 5"))
        try await harness.performRoot("copy-question-and-answer", on: other, query: "5 * 5")
        let hex = try #require(harness.answerRow("0x10"))
        try await harness.performRoot("copy-form-0", on: hex, query: "0x10")
        #expect(harness.feature.history.entries.map(\.question) == ["5 * 5", "0xff + 1"])
    }

    @Test func historyOffKeepsNothingNewAndTheListSaysSo() async throws {
        let harness = await readyHarness()
        try await copy("2 + 2", in: harness)
        harness.context.settings[CalcSettings.keepsHistory] = false
        try await copy("3 + 3", in: harness)
        #expect(harness.feature.history.entries.map(\.question) == ["2 + 2"], "what was saved stays")
        await harness.feature.history.clear()
        try await harness.run("history")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Calculator History Is Off")
        harness.context.settings[CalcSettings.keepsHistory] = true
        try await harness.settle()
        #expect(harness.page?.emptyState?.title == "No Calculator History")
    }

    @Test func theCapKeepsTheNewestAndLoweringItTrimsAtOnce() async throws {
        let harness = await readyHarness()
        harness.context.settings[CalcSettings.historyLimit] = 25
        try await harness.settle()
        for n in 1...30 {
            harness.fakes.clock.advance(by: .seconds(1))
            try await copy("\(n) + 1", in: harness)
        }
        #expect(harness.feature.history.entries.count == 25)
        #expect(harness.feature.history.entries.first?.question == "30 + 1")
        #expect(harness.feature.history.entries.last?.question == "6 + 1")
        harness.context.settings[CalcSettings.historyLimit] = 3
        try await harness.settle()
        #expect(harness.feature.history.entries.map(\.question) == ["30 + 1", "29 + 1", "28 + 1"])
        harness.context.settings[CalcSettings.historyLimit] = -5
        #expect(harness.feature.history.limit == 1, "a hand-written limit is kept in bounds")
    }

    @Test func useAgainPutsTheQuestionBackInRootSearch() async throws {
        let harness = await readyHarness()
        try await copy("100 km in miles", in: harness)
        try await harness.run("history")
        let actions = harness.actions()
        #expect(actions.map(\.id).prefix(2) == ["copy", "use-again"])
        let outcome = try await harness.performSecondary()
        #expect(outcome.kind == .showRoot(query: "100 km in miles"))
        #expect(harness.rootQueries == ["100 km in miles"])
    }

    @Test func deleteAndClearAskFirst() async throws {
        let harness = await readyHarness()
        try await copy("1 + 1", in: harness)
        try await copy("2 + 2", in: harness)
        try await copy("3 + 3", in: harness)
        try await harness.run("history")
        try harness.select(title: "6")
        harness.confirmationAnswer = false
        try await harness.perform("delete")
        #expect(harness.feature.history.entries.count == 3, "a declined question deletes nothing")
        harness.confirmationAnswer = true
        try await harness.perform("delete")
        #expect(harness.confirmations.map(\.title).last == "Delete “3 + 3” from History?")
        #expect(harness.rows.map(\.title) == ["4", "2"], "the open list follows")
        #expect(harness.visibleToast?.title == "Deleted Answer")
        try await harness.perform("clear-history")
        #expect(harness.confirmations.last?.isDestructive == true)
        #expect(harness.rows.isEmpty)
        #expect(harness.feature.history.entries.isEmpty)
        #expect(harness.visibleToast?.title == "Cleared Calculator History")
    }

    @Test func theSettingsButtonClearsAfterAsking() async throws {
        let harness = await readyHarness()
        try await copy("1 + 1", in: harness)
        harness.confirmationAnswer = false
        try await harness.pressSettingsButton("Clear History")
        #expect(harness.feature.history.entries.count == 1)
        harness.confirmationAnswer = true
        try await harness.pressSettingsButton("Clear History")
        #expect(harness.feature.history.entries.isEmpty)
        #expect(harness.toasts.last?.title == "Cleared Calculator History")
    }

    @Test func aDamagedFileIsSetAsideAndANewHistoryStarts() async throws {
        let fakes = FakeServices()
        let folder = fakes.storage.dataDirectory(for: "calculator")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "history.json")
        try Data("{ \"entries\": [ broken".utf8).write(to: file)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.isEmpty)
        let aside = folder.appending(path: "history-damaged-1.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ \"entries\": [ broken")
        try await copy("2 + 2", in: harness)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "the damaged copy is never overwritten")
    }

    @Test func historyRowsWorkFromTheirPayloadAlone() async throws {
        let harness = await readyHarness()
        try await copy("2 + 2", in: harness)
        try await harness.run("history")
        let row = try #require(harness.rows.first)
        let rebuilt = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        #expect(harness.feature.historyList.actions(for: rebuilt).map(\.id) == harness.actions().map(\.id))
    }
}
