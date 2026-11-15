import CoreBridge
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import Calc

/// A harness over the fakes with the engine ready, as after activation in the app. The region is
/// New York in US English unless a test passes another; the clock is the fakes' Saturday
/// 14 November 2026, 09:30 UTC.
func readyHarness(
    fakes: FakeServices = FakeServices(), region: TestRegion = TestRegion(), rates: (any ExchangeRateService)? = nil
) async -> FeatureHarness<CalculatorFeature> {
    fakes.override(RegionServiceKey.self, with: region)
    fakes.override(ExchangeRateServiceKey.self, with: rates ?? ScriptedRates())
    let harness = FeatureHarness(CalculatorFeature.self, fakes: fakes)
    await harness.activate()
    await harness.feature.waitUntilReady()
    return harness
}

extension FeatureHarness where F == CalculatorFeature {
    /// The provider's one row for a query, or nil when it answers nothing.
    func answerRow(_ query: String) -> Row? {
        instantAnswers(for: query).first?.rows.first
    }

    /// The payload of the provider's row for a query.
    func payload(_ query: String) throws -> AnswerPayload {
        let row = try #require(answerRow(query), "no answer for \(query)")
        return try #require(try row.payload?.decode(AnswerPayload.self))
    }
}

/// A region a test can change, with a change stream whose consumer the test can wait for.
final class TestRegion: RegionService, @unchecked Sendable {
    private struct State {
        var snapshot: RegionSnapshot
        var continuations: [AsyncStream<Void>.Continuation] = []
        var sent = 0
    }

    private let state: Mutex<State>

    init(locale: String = "en_US", timeZone: String = "America/New_York") {
        state = Mutex(
            State(
                snapshot: RegionSnapshot(
                    locale: Locale(identifier: locale), timeZone: TimeZone(identifier: timeZone) ?? .gmt)))
    }

    var current: RegionSnapshot { state.withLock { $0.snapshot } }

    var subscriberCount: Int { state.withLock { $0.continuations.count } }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }

    /// Changes the region and tells every subscriber.
    func change(locale: String? = nil, timeZone: String? = nil) {
        let continuations = state.withLock { state in
            if let locale { state.snapshot.locale = Locale(identifier: locale) }
            if let timeZone { state.snapshot.timeZone = TimeZone(identifier: timeZone) ?? .gmt }
            state.sent += 1
            return state.continuations
        }
        for continuation in continuations { continuation.yield() }
    }
}

/// A rate service that answers from a script and counts what it was asked. `hold` keeps the next
/// download open until `release()`, so a test can see the loading state.
final class ScriptedRates: ExchangeRateService, @unchecked Sendable {
    private struct State {
        var saved: RateTable?
        var next: [Result<RateTable, ExchangeRateFailure>] = []
        var downloads: [Date] = []
        var held: CheckedContinuation<Void, Never>?
        var holds = false
    }

    private let state: Mutex<State>

    init(saved: RateTable? = nil, next: [Result<RateTable, ExchangeRateFailure>] = []) {
        state = Mutex(State(saved: saved, next: next))
    }

    var downloads: [Date] { state.withLock { $0.downloads } }

    func enqueue(_ result: Result<RateTable, ExchangeRateFailure>) {
        state.withLock { $0.next.append(result) }
    }

    func hold() {
        state.withLock { $0.holds = true }
    }

    func release() {
        let held = state.withLock { state in
            state.holds = false
            let held = state.held
            state.held = nil
            return held
        }
        held?.resume()
    }

    func savedTable() async -> RateTable? {
        state.withLock { $0.saved }
    }

    func download(at now: Date) async throws -> RateTable {
        let holds = state.withLock { state in
            state.downloads.append(now)
            return state.holds
        }
        if holds {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.holds else { return true }
                    state.held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let result = state.withLock { state -> Result<RateTable, ExchangeRateFailure> in
            state.next.isEmpty ? .failure(.unreachable) : state.next.removeFirst()
        }
        let table = try result.get()
        state.withLock { $0.saved = table }
        return table
    }
}

/// Made-up rates in the European Central Bank's shape: units per euro.
nonisolated let sampleRates: [String: Double] = [
    "USD": 1.25, "JPY": 160, "GBP": 0.8, "CHF": 0.95, "CAD": 1.5, "AUD": 1.6, "NZD": 1.75, "SEK": 11,
    "NOK": 11.5, "DKK": 7.5, "PLN": 4.25, "CZK": 25, "HUF": 400, "CNY": 8, "HKD": 9.5, "SGD": 1.6,
]

/// A table for a day, downloaded at a moment.
nonisolated func sampleTable(
    day: String = "2026-11-13", downloadedAt: Date = Date(timeIntervalSince1970: 1_794_648_600)
)
    -> RateTable
{
    RateTable(base: "EUR", day: day, downloadedAt: downloadedAt, rates: sampleRates)
}

/// The bank's daily file, written by hand in its published format, with made-up rates.
nonisolated func referenceXML(day: String = "2026-11-13", rates: [(String, String)]? = nil) -> String {
    let lines = (rates ?? sampleRates.sorted { $0.key < $1.key }.map { ($0.key, String($0.value)) })
        .map { "\t\t\t<Cube currency='\($0.0)' rate='\($0.1)'/>" }
        .joined(separator: "\n")
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" \
        xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
        \t<gesmes:subject>Reference rates</gesmes:subject>
        \t<gesmes:Sender>
        \t\t<gesmes:name>European Central Bank</gesmes:name>
        \t</gesmes:Sender>
        \t<Cube>
        \t\t<Cube time='\(day)'>
        \(lines)
        \t\t</Cube>
        \t</Cube>
        </gesmes:Envelope>
        """
}

/// The fake clock's start, Saturday 14 November 2026, 09:30 UTC.
nonisolated let fakeStart = Date(timeIntervalSince1970: 1_794_648_600)
