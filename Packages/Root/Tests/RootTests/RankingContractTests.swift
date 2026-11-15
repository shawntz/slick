import CoreBridge
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

/// The ranking contract in docs/ARCHITECTURE.md, checked through root search's own seam: rows in,
/// update(query:) and didRun out, over the real engine.
@Suite struct RankingContractTests {
    @Test func aUserAliasRanksFirstExactlyAndByPrefix() async throws {
        let fixture = await RootFixture.ready()
        #expect(fixture.results("ed").first == "Editor")

        fixture.preferences.setAlias("edit", for: fixture.apps.id("Calendar"))
        await fixture.settle()
        #expect(fixture.results("edit").first == "Calendar")
        #expect(fixture.results("ed").first == "Calendar")

        fixture.preferences.setAlias(nil, for: fixture.apps.id("Calendar"))
        await fixture.settle()
        #expect(fixture.results("ed").first == "Editor")
        await fixture.shutdown()
    }

    @Test func twoPicksEnterTheLearnedBandAboveAnExactTitle() async throws {
        let fixture = await RootFixture.ready()
        #expect(fixture.results("term").prefix(2) == ["Term", "Terminal"])

        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        #expect(fixture.results("term").first == "Terminal")
        await fixture.shutdown()
    }

    @Test func oneStrayPickDoesNotFlipAHabit() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Term", for: "term")
        #expect(fixture.results("term").first == "Terminal")

        try await fixture.pick("Term", for: "term")
        #expect(fixture.results("term").first == "Term")
        await fixture.shutdown()
    }

    @Test func theSameQueryInTheSameStateKeepsItsOrder() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Terminal", for: "te")
        _ = fixture.root.begin()
        let first = fixture.root.update(query: "e").rows.map(\.id)
        let again = fixture.root.update(query: "e").rows.map(\.id)
        fixture.root.end()
        _ = fixture.root.begin()
        let narrowed = fixture.root.update(query: "e").rows.map(\.id)
        #expect(first.count > 3)
        #expect(first == again)
        #expect(first == narrowed)
        await fixture.shutdown()
    }

    @Test func picksFromSuggestionsAndFavoritesNeverTeachTheQuery() async throws {
        let fixture = await RootFixture.ready()
        let terminal = try #require(fixture.root.row(for: fixture.apps.id("Terminal")))
        _ = fixture.root.begin()
        for _ in 0..<3 { fixture.root.didRun(terminal, launch: .suggestion) }
        fixture.root.end()
        fixture.preferences.setFavorites([terminal.id])
        await fixture.settle()
        let favorites = fixture.root.begin()
        #expect(favorites.section(containing: terminal.id)?.kind == .favorites)
        for _ in 0..<3 { fixture.root.didRun(terminal, launch: .root) }
        fixture.root.end()
        await fixture.settle()

        #expect(fixture.results("term").first == "Term")
        #expect(fixture.root.usage.useCount(of: terminal.id) == 6)
        await fixture.shutdown()
    }

    @Test func anAliasPickIsNotTypedLearning() async throws {
        let fixture = await RootFixture.ready()
        fixture.preferences.setAlias("tm", for: fixture.apps.id("Terminal"))
        await fixture.settle()
        _ = fixture.root.begin()
        let snapshot = fixture.root.update(query: "tm")
        let terminal = try #require(snapshot.rows.first)
        #expect(terminal.title == "Terminal")
        #expect(fixture.root.executionSource(for: terminal, launch: .root).source == .alias)
        fixture.root.end()
        await fixture.shutdown()
    }
}
