import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// What a second pass found: settings that delete, files from elsewhere, stale rows and odd text.
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    private func copy(_ query: String, in harness: FeatureHarness<CalculatorFeature>) async throws {
        let row = try #require(harness.answerRow(query), "no answer for \(query)")
        try await harness.performRoot("copy", on: row, query: query)
    }

    private func historyFile(_ fakes: FakeServices) throws -> URL {
        let folder = fakes.storage.dataDirectory(for: "calculator")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "history.json")
    }

    @Test func aSmallerHistorySizeAsksFirstAndALargerOneDoesNot() async throws {
        let harness = await readyHarness()
        for n in 1...30 {
            harness.fakes.clock.advance(by: .seconds(1))
            try await copy("\(n) + 1", in: harness)
        }
        harness.confirmationAnswer = false
        #expect(try harness.chooseSetting("Keep at most", option: "25 Answers") == false)
        try await harness.settle()
        #expect(harness.confirmations.map(\.title) == ["Keep Only 25 Answers?"])
        #expect(harness.confirmations.first?.isDestructive == true)
        #expect(harness.feature.history.entries.count == 30, "a declined question deletes nothing")
        #expect(harness.context.settings[CalcSettings.historyLimit] == 100)

        harness.confirmationAnswer = true
        #expect(try harness.chooseSetting("Keep at most", option: "25 Answers"))
        try await harness.settle()
        #expect(harness.feature.history.entries.count == 25)

        #expect(try harness.chooseSetting("Keep at most", option: "250 Answers"))
        #expect(harness.confirmations.count == 2, "a larger size loses nothing and asks nothing")
    }

    @Test func aHistoryFileFromANewerVersionIsShownButNeverOverwritten() async throws {
        let fakes = FakeServices()
        let file = try historyFile(fakes)
        let newer = """
            {
              "version" : 2,
              "colour" : "teal",
              "entries" : [
                {
                  "id" : "00000000-0000-0000-0000-000000000001",
                  "question" : "6 * 7",
                  "answer" : "42",
                  "date" : "2026-11-14T09:00:00.000Z",
                  "pinned" : true
                }
              ]
            }
            """
        try Data(newer.utf8).write(to: file)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.map(\.answer) == ["42"])
        #expect(harness.feature.status?.title == "Calculator History Is Read Only")
        #expect(harness.feature.status?.level == .warning)

        try await copy("2 + 2", in: harness)
        try await harness.run("history")
        #expect(harness.rows.map(\.title) == ["4", "42"], "new answers show for this session")
        try await harness.perform("delete")
        try await harness.perform("clear-history")
        #expect(try String(contentsOf: file, encoding: .utf8) == newer, "the newer file is never written")
        #expect(harness.issues.isEmpty)
    }

    @Test func aHandEditedHistoryShowsOneLineTitlesAndDropsEmptyEntries() async throws {
        let fakes = FakeServices()
        let file = try historyFile(fakes)
        let edited = """
            {
              "version" : 1,
              "entries" : [
                { "id" : "00000000-0000-0000-0000-000000000001", "question" : "2 +\\n 2",
                  "answer" : "4\\u2028four", "date" : "2026-11-14T09:00:00.000Z" },
                { "id" : "00000000-0000-0000-0000-000000000001", "question" : "again",
                  "answer" : "the same id", "date" : "2026-11-14T08:00:00.000Z" },
                { "id" : "00000000-0000-0000-0000-000000000002", "question" : "1 + 1",
                  "answer" : " \\t ", "date" : "2026-11-14T07:00:00.000Z" },
                { "id" : "00000000-0000-0000-0000-000000000003", "question" : "\\u202e7 * 6",
                  "answer" : "42", "date" : "2026-11-14T06:00:00.000Z" }
              ]
            }
            """
        try Data(edited.utf8).write(to: file)
        let harness = await readyHarness(fakes: fakes)
        try await harness.run("history")
        #expect(harness.rows.map(\.title) == ["4 four", "42"])
        #expect(harness.rows.map(\.subtitle) == ["2 + 2", "7 * 6"])
        #expect(harness.feature.status == nil)
    }

    @Test func aRowMadeBeforeDownloadsWereTurnedOffSendsNothing() async throws {
        let rates = ScriptedRates(next: [.failure(.unreachable)])
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        await harness.feature.rates.waitForDownload()
        let stale = try #require(harness.answerRow("100 usd in eur"))
        #expect(stale.title == "Exchange Rates Unavailable")

        harness.context.settings[CalcSettings.downloadsRates] = false
        try await harness.settle()
        harness.throwsActionErrors = false
        try await harness.performRoot("try-again", on: stale, query: "100 usd in eur")
        #expect(rates.downloads.count == 1, "the old row asks no download once downloads are off")
        #expect(harness.visibleToast?.title == "Exchange Rates Are Off")
        #expect(harness.rootQueries.isEmpty)
        #expect(await harness.feature.rates.downloadNow() == false)
        #expect(rates.downloads.count == 1)
    }

    @Test func refreshExchangeRatesDownloadsAgainWhateverTheirAge() async throws {
        let rates = ScriptedRates(saved: sampleTable(downloadedAt: fakeStart))
        let harness = await readyHarness(rates: rates)
        let row = try #require(harness.answerRow("5 usd in eur"))
        #expect(row.title == "4 EUR")
        #expect(harness.feature.rates.downloadCount == 0, "a table from today is not downloaded again")
        let actions = harness.rootActions(for: row)
        #expect(actions.map(\.id).contains("refresh-rates"))
        #expect(actions.first { $0.id == "refresh-rates" }?.shortcut == .refresh)
        #expect(
            harness.rootActions(for: try #require(harness.answerRow("2 + 2"))).map(\.id).contains("refresh-rates")
                == false)

        rates.enqueue(.success(sampleTable(day: "2026-11-14", downloadedAt: fakeStart)))
        let outcome = try await harness.performRoot("refresh-rates", on: row, query: "5 usd in eur")
        #expect(outcome.kind == .showRoot(query: "5 usd in eur"))
        #expect(rates.downloads.count == 1)
        #expect(harness.answerRow("5 usd in eur")?.subtitle == "Currency · Rates from 14 Nov 2026")

        harness.context.settings[CalcSettings.downloadsRates] = false
        try await harness.settle()
        let offRow = try #require(harness.answerRow("5 usd in eur"))
        #expect(!harness.rootActions(for: offRow).map(\.id).contains("refresh-rates"), "hidden while downloads are off")
    }

    @Test func confirmationsNameWhatTheyDeleteInTitleCase() async throws {
        let harness = await readyHarness()
        try await copy("12 * 3", in: harness)
        try await harness.run("history")
        let delete = try #require(harness.actions().first { $0.id == "delete" })
        #expect(delete.confirmation?.title == "Delete “12 * 3” from History?")
        let clear = try #require(harness.actions().first { $0.id == "clear-history" })
        #expect(clear.confirmation?.title == "Clear Calculator History?")
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func aDeepLinkToTheHistoryOnlyOpensThePage() async throws {
        let harness = await readyHarness()
        try await copy("1 + 1", in: harness)
        let outcome = try await harness.run("history", launch: .deeplink)
        #expect(outcome.kind == .push)
        #expect(harness.fakes.pasteboard.copiedTexts == ["2"], "the link copied and deleted nothing")
        #expect(harness.feature.history.entries.count == 1)
    }

    @Test func titlesStayOnOneLineAndKeepDigitGroupingSpaces() {
        #expect(CalcStrings.oneLine("  a\nb\r\nc\u{2029}d\te  ") == "a b c d e")
        #expect(CalcStrings.oneLine("1\u{202F}234\u{00A0}567") == "1\u{202F}234\u{00A0}567")
        #expect(CalcStrings.oneLine("\u{202E}abc\u{2066}") == "abc")
        #expect(CalcStrings.oneLine("\n\t ") == "")
    }

    @Test func aQuestionWithATabIsKeptOnOneLine() async throws {
        let harness = await readyHarness()
        try await copy("2 +\t2", in: harness)
        #expect(harness.feature.history.entries.map(\.question) == ["2 + 2"])
    }
}

/// Digits and signs typed in full width or in another script.
@Suite("Digits of every script", .timeLimit(.minutes(1)))
struct FoldingTests {
    @Test(arguments: [
        ("１＋１", "2"), ("２×３", "6"), ("١٢+٣", "15"), ("१० * २", "20"), ("１２３４５ * ２", "24,690"),
        ("５\u{3000}km in m", "5,000 m"), ("١٫٥ + ١", "2.5"),
    ])
    func otherDigitsAnswerAsASCIIDigitsDo(query: String, expected: String) async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow(query), "no answer for \(query)")
        #expect(row.title == expected)
        let payload = try harness.payload(query)
        #expect(payload.question == query, "the question stays as typed")
    }

    @Test func textWithoutFoldableCharactersIsLeftAlone() {
        #expect(QueryFolding.folded("2 + 2") == nil)
        #expect(QueryFolding.folded("£5 + €3") == nil)
        #expect(QueryFolding.folded("こんにちは") == nil)
        #expect(QueryFolding.folded("x²") == nil, "a superscript is not a digit to fold")
        #expect(QueryFolding.folded("Ａｂｃ") == nil, "letters alone are not math, so nothing is made")
        #expect(QueryFolding.folded("Ａｂｃ １") == "Abc 1")
    }

    @Test func foreignTextIsStillTurnedAway() async throws {
        let harness = await readyHarness()
        for query in ["こんにちは", "第１章", "مرحبا", "👍", "Ｓａｆａｒｉ"] {
            #expect(harness.answerRow(query) == nil, "\(query)")
        }
    }
}
