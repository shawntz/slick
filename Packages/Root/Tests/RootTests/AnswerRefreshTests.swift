import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

/// An instant provider whose answers a test sets, with a change signal, as a currency conversion
/// that waits for rates does.
final class RateAnswers: InstantProvider {
    let namespace = "rate"
    let signal = ChangeSignal()
    /// Rows by query. A query with no entry has no answer.
    var answers: [String: [Row]] = [:]
    var claimsTop = true
    private(set) var asked: [String] = []

    var answersChanged: ChangeSignal? { signal }

    func answer(for query: String) -> InstantAnswer? {
        asked.append(query)
        guard let rows = answers[query] else { return nil }
        return InstantAnswer(rows: rows, claimsTop: claimsTop, sectionTitle: "Rates")
    }

    func actions(for row: Row) -> [Action] {
        [Action("Copy Answer") { _ in .close() }]
    }

    static func row(_ key: String, _ title: String, completion: String? = nil) -> Row {
        Row(id: ItemID("rate", key), title: title, completion: completion, memory: .never)
    }
}

final class RatesFeature: Feature {
    static let manifest = FeatureManifest(id: "rates", name: "Rates", icon: .symbol("dollarsign"))
    let rates = RateAnswers()

    init(context: FeatureContext) {}

    var liveProviders: [LiveProvider] { [.instant(rates)] }
}

@Suite(.timeLimit(.minutes(1))) struct AnswerRefreshTests {
    private func ratesFixture() async -> (RootFixture, RateAnswers) {
        let fixture = await RootFixture.ready()
        let feature = fixture.directory.register(RatesFeature.self, fakes: fixture.fakes)
        await fixture.settle()
        return (fixture, feature.rates)
    }

    @Test func aLoadingRowAtTheTopTurnsIntoTheAnswerInPlace() async throws {
        let (fixture, rates) = await ratesFixture()
        rates.answers["5 usd in eur"] = [RateAnswers.row("5usd-eur", "Loading Rates")]
        _ = fixture.root.begin()
        let typed = fixture.root.update(query: "5 usd in eur")
        #expect(typed.sections.first?.kind == .answers)
        #expect(typed.rows.first?.title == "Loading Rates")
        let generation = fixture.root.changes.generation

        rates.answers["5 usd in eur"] = [RateAnswers.row("5usd-eur", "4.60 EUR", completion: "4.6")]
        rates.signal.send()
        await fixture.settle()
        let now = fixture.root.snapshot
        #expect(fixture.root.changes.generation > generation)
        #expect(now.revision > typed.revision)
        #expect(now.rows.first?.title == "4.60 EUR")
        #expect(now.sections.map(\.id) == typed.sections.map(\.id))
        #expect(Array(now.rows.dropFirst()) == Array(typed.rows.dropFirst()))
        #expect(now.completion == RootCompletion(id: ItemID("rate", "5usd-eur"), text: "4.6"))
        #expect(rates.asked.suffix(1) == ["5 usd in eur"])
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func theCompletionFollowsTheNewAnswerOfTheSameRow() async throws {
        let (fixture, rates) = await ratesFixture()
        rates.answers["5 usd in eur"] = [RateAnswers.row("5usd-eur", "4.50 EUR", completion: "4.5")]
        _ = fixture.root.begin()
        #expect(fixture.root.update(query: "5 usd in eur").completion?.text == "4.5")
        rates.answers["5 usd in eur"] = [RateAnswers.row("5usd-eur", "4.60 EUR", completion: "4.6")]
        rates.signal.send()
        await fixture.settle()
        #expect(fixture.root.snapshot.completion?.text == "4.6")

        rates.answers["5 usd in eur"] = [RateAnswers.row("5usd-eur", "Rates Unavailable")]
        rates.signal.send()
        await fixture.settle()
        #expect(fixture.root.snapshot.completion == nil)
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func rowsInTheProvidersOwnSectionChangeWithoutMovingTheResultsAbove() async throws {
        let (fixture, rates) = await ratesFixture()
        rates.claimsTop = false
        rates.answers["term"] = [RateAnswers.row("a", "First Rate")]
        _ = fixture.root.begin()
        let typed = fixture.root.update(query: "term")
        let results = try #require(typed.sections.first { $0.kind == .results })
        #expect(typed.sections.first?.kind == .results)

        rates.answers["term"] = [RateAnswers.row("a", "First Rate"), RateAnswers.row("b", "Second Rate")]
        rates.signal.send()
        await fixture.settle()
        let now = fixture.root.snapshot
        #expect(now.sections.first == results)
        let own = try #require(now.sections.first { $0.id == "provider.rate" })
        #expect(own.rows.map(\.title) == ["First Rate", "Second Rate"])
        #expect(own.title == "Rates")
        #expect(now.sections.map(\.id) == typed.sections.map(\.id))
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aNewAnswerJoinsAfterTheResultsAndANilAnswerLeaves() async throws {
        let (fixture, rates) = await ratesFixture()
        _ = fixture.root.begin()
        let typed = fixture.root.update(query: "term")
        #expect(!typed.sections.contains { $0.id == "provider.rate" })

        // A provider that claims the top still never pushes rows above what the user sees.
        rates.answers["term"] = [RateAnswers.row("late", "Late Rate")]
        rates.signal.send()
        await fixture.settle()
        let joined = fixture.root.snapshot
        #expect(joined.sections.first == typed.sections.first)
        let ids = joined.sections.map(\.id)
        let own = try #require(ids.firstIndex(of: "provider.rate"))
        let results = try #require(ids.firstIndex(of: "results"))
        let fallbacks = try #require(ids.firstIndex(of: "fallbacks"))
        #expect(results < own && own < fallbacks)

        rates.answers["term"] = nil
        rates.signal.send()
        await fixture.settle()
        #expect(fixture.root.snapshot.sections.map(\.id) == typed.sections.map(\.id))
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aSignalOutsideASessionOrForABlankQueryAsksNothing() async throws {
        let (fixture, rates) = await ratesFixture()
        rates.signal.send()
        await fixture.settle()
        #expect(rates.asked.isEmpty)

        _ = fixture.root.begin()
        _ = fixture.root.update(query: "  ")
        rates.signal.send()
        await fixture.settle()
        #expect(rates.asked.isEmpty)

        _ = fixture.root.update(query: "zz")
        let asked = rates.asked.count
        let revision = fixture.root.snapshot.revision
        rates.signal.send()
        await fixture.settle()
        // Asked once more, and nothing changed, so nothing was published.
        #expect(rates.asked.count == asked + 1)
        #expect(fixture.root.snapshot.revision == revision)
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aProviderWhoseFeatureLeftIsNoLongerFollowed() async throws {
        let (fixture, rates) = await ratesFixture()
        #expect(rates.signal.listenerCount == 1)
        fixture.directory.setEnabled(false, feature: "rates")
        await fixture.settle()
        #expect(rates.signal.listenerCount == 0)
        await fixture.shutdown()
    }
}
