import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

/// When rates are downloaded, and what a currency question shows meanwhile.
@Suite("Exchange rates", .timeLimit(.minutes(1)))
struct RateKeeperTests {
    /// Waits for the download the last keystroke started.
    private func finishDownload(_ harness: FeatureHarness<CalculatorFeature>) async {
        await harness.feature.rates.waitForDownload()
    }

    @Test func nothingIsDownloadedUntilACurrencyConversionIsTyped() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable())])
        let harness = await readyHarness(rates: rates)
        #expect(harness.feature.rates.downloadCount == 0, "activation downloads nothing")
        _ = harness.answerRow("2 + 2")
        _ = harness.answerRow("$5")
        _ = harness.answerRow("5 usd")
        #expect(harness.feature.rates.downloadCount == 0, "an amount without a conversion downloads nothing")

        let loading = try harness.payload("100 usd in eur")
        #expect(loading.status == .ratesLoading)
        #expect(harness.answerRow("100 usd in eur")?.title == "Loading Exchange Rates")
        #expect(harness.feature.rates.downloadCount == 1, "one download however many keystrokes")
        await finishDownload(harness)
        let row = try #require(harness.answerRow("100 usd in eur"))
        #expect(row.title == "80 EUR")
        #expect(row.subtitle == "Currency · Rates from 13 Nov 2026")
        #expect(harness.feature.rates.downloadCount == 1)
    }

    @Test func atMostOneDownloadADay() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable(downloadedAt: fakeStart))])
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        await finishDownload(harness)
        harness.fakes.clock.advance(by: .seconds(23 * 3600))
        _ = harness.answerRow("100 usd in gbp")
        #expect(harness.feature.rates.downloadCount == 1)
        harness.fakes.clock.advance(by: .seconds(2 * 3600))
        rates.enqueue(.success(sampleTable(day: "2026-11-14", downloadedAt: harness.fakes.clock.now)))
        let stale = try #require(harness.answerRow("100 usd in gbp"))
        #expect(stale.title == "64 GBP", "the day-old table answers while the new one downloads")
        #expect(harness.feature.rates.downloadCount == 2)
        await finishDownload(harness)
        #expect(harness.answerRow("100 usd in gbp")?.subtitle == "Currency · Rates from 14 Nov 2026")
    }

    @Test func noNetworkSaysSoAndTriesAgainLater() async throws {
        let rates = ScriptedRates(next: [.failure(.unreachable)])
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        await finishDownload(harness)
        let row = try #require(harness.answerRow("100 usd in eur"))
        #expect(row.title == "Exchange Rates Unavailable")
        #expect(row.subtitle == "The European Central Bank could not be reached. Press Return to try again.")
        #expect(harness.feature.rates.downloadCount == 1, "no retry on every keystroke")
        harness.fakes.clock.advance(by: .seconds(29 * 60))
        _ = harness.answerRow("100 usd in eur")
        #expect(harness.feature.rates.downloadCount == 1)
        harness.fakes.clock.advance(by: .seconds(2 * 60))
        rates.enqueue(.success(sampleTable()))
        _ = harness.answerRow("100 usd in eur")
        #expect(harness.feature.rates.downloadCount == 2)
        await finishDownload(harness)
        #expect(harness.answerRow("100 usd in eur")?.title == "80 EUR")
    }

    @Test func tryAgainDownloadsAtOnceAndShowsTheQuestionAgain() async throws {
        let rates = ScriptedRates(next: [.failure(.status(503))])
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        await finishDownload(harness)
        let row = try #require(harness.answerRow("100 usd in eur"))
        rates.enqueue(.success(sampleTable()))
        let outcome = try await harness.performRoot("try-again", on: row, query: "100 usd in eur")
        #expect(outcome.kind == .showRoot(query: "100 usd in eur"))
        #expect(harness.rootQueries == ["100 usd in eur"])
        #expect(harness.feature.rates.downloadCount == 2)
        #expect(harness.answerRow("100 usd in eur")?.title == "80 EUR")

        harness.throwsActionErrors = false
        harness.feature.rates.cancel()
        let failing = ScriptedRates(next: [.failure(.unreachable), .failure(.unreachable)])
        let offline = await readyHarness(rates: failing)
        _ = offline.answerRow("1 usd in eur")
        await finishDownload(offline)
        offline.throwsActionErrors = false
        try await offline.performRoot(
            "try-again", on: try #require(offline.answerRow("1 usd in eur")), query: "1 usd in eur")
        #expect(offline.visibleToast?.title == "Exchange Rates Unavailable")
        #expect(offline.rootQueries.isEmpty)
    }

    @Test func showAnswerWaitsForTheDownloadThatIsRunning() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable())])
        rates.hold()
        let harness = await readyHarness(rates: rates)
        let row = try #require(harness.answerRow("100 usd in eur"))
        #expect(row.title == "Loading Exchange Rates")
        let actions = harness.rootActions(for: row)
        #expect(actions.map(\.title) == ["Show Answer"])
        async let outcome = harness.performRoot("show-answer", on: row, query: "100 usd in eur")
        await Task.yield()
        rates.release()
        #expect(try await outcome.kind == .showRoot(query: "100 usd in eur"))
        #expect(harness.feature.rates.downloadCount == 1, "the action joined the running download")
    }

    @Test func turningDownloadsOffStopsThemAndTheRowSaysHowToTurnThemOn() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable())])
        let harness = await readyHarness(rates: rates)
        harness.context.settings[CalcSettings.downloadsRates] = false
        try await harness.settle()
        let row = try #require(harness.answerRow("100 usd in eur"))
        #expect(row.title == "Exchange Rates Are Off")
        #expect(harness.feature.rates.downloadCount == 0)
        let outcome = try await harness.performRoot("turn-on-rates", on: row, query: "100 usd in eur")
        #expect(outcome.kind == .showRoot(query: "100 usd in eur"))
        #expect(harness.context.settings[CalcSettings.downloadsRates])
        #expect(harness.feature.rates.downloadCount == 1)
        #expect(harness.answerRow("100 usd in eur")?.title == "80 EUR")
    }

    @Test func turningDownloadsOffCancelsOneThatIsRunning() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable())])
        rates.hold()
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        #expect(harness.feature.rates.state == .loading)
        harness.context.settings[CalcSettings.downloadsRates] = false
        try await harness.settle()
        #expect(harness.feature.rates.state == .idle)
        rates.release()
        #expect(harness.answerRow("100 usd in eur")?.title == "Exchange Rates Are Off")
    }

    @Test func anOldSavedTableAnswersAtOnceWithItsDateAndIsReplaced() async throws {
        let old = sampleTable(day: "2026-11-02", downloadedAt: fakeStart.addingTimeInterval(-12 * 24 * 3600))
        let rates = ScriptedRates(saved: old, next: [.success(sampleTable(day: "2026-11-13"))])
        let harness = await readyHarness(rates: rates)
        #expect(harness.feature.rates.downloadCount == 0, "a saved table is read, not refreshed, at activation")
        let row = try #require(harness.answerRow("100 usd in eur"))
        #expect(row.title == "80 EUR")
        #expect(row.subtitle == "Currency · Rates from 2 Nov 2026")
        #expect(harness.feature.rates.downloadCount == 1)
        await finishDownload(harness)
        #expect(harness.answerRow("100 usd in eur")?.subtitle == "Currency · Rates from 13 Nov 2026")
    }

    @Test func aCurrencyTheBankDoesNotListSaysSo() async throws {
        let harness = await readyHarness(rates: ScriptedRates(saved: sampleTable(downloadedAt: fakeStart)))
        let row = try #require(harness.answerRow("100 usd in ars"))
        #expect(row.subtitle == "The European Central Bank publishes no rate for this currency.")
    }

    @Test func theFeatureOverTheBankServiceAndFakeHTTP() async throws {
        let fakes = FakeServices()
        let file = fakes.storage.dataDirectory(for: "calculator").appending(path: ReferenceRates.fileName)
        let address = try #require(ReferenceRates.address)
        fakes.http.stub(address, response: HTTPResponse(status: 200, body: Data(referenceXML().utf8)))
        let harness = await readyHarness(fakes: fakes, rates: ReferenceRates(http: fakes.http, file: file))
        #expect(fakes.http.requests.isEmpty)
        _ = harness.answerRow("100 usd in eur")
        await finishDownload(harness)
        #expect(harness.answerRow("100 usd in eur")?.title == "80 EUR")
        #expect(fakes.http.requests.map(\.url) == [address])

        // The next launch reads the saved table and needs no request.
        let next = await readyHarness(fakes: fakes, rates: ReferenceRates(http: fakes.http, file: file))
        #expect(next.answerRow("100 usd in eur")?.title == "80 EUR")
        #expect(fakes.http.requests.count == 1)
    }

    @Test func deactivatingCancelsARunningDownload() async throws {
        let rates = ScriptedRates(next: [.success(sampleTable())])
        rates.hold()
        let harness = await readyHarness(rates: rates)
        _ = harness.answerRow("100 usd in eur")
        await harness.deactivate()
        #expect(harness.feature.rates.state == .idle)
        rates.release()
        await Task.yield()
        #expect(harness.feature.rates.table == nil)
    }
}
