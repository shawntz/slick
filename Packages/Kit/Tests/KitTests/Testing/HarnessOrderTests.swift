import Kit
import KitTesting
import Testing

/// The harness orders a host-filtered list as the host does: by tier, then a title match before a
/// keyword match, then rank hint, then the index's order.
@Suite("FeatureHarness: host filtering order", .timeLimit(.minutes(1)))
struct HarnessOrderTests {
    /// A grid of made-up glyphs with keywords and rank hints, filtered by the host.
    final class Glyphs: Feature, ListSource {
        static let manifest = FeatureManifest(id: "glyphs", name: "Glyphs", icon: .glyph("G"))
        init(context: FeatureContext) {}

        var commands: [Command] {
            [Command(id: "open", title: "Open Glyphs") { _ in .push(.list(ListPage(self))) }]
        }

        func load(_ request: ListRequest) async throws -> ListResult {
            let rows = [
                Row(id: ItemID("glyphs", "crimson"), title: "Crimson Heart", keywords: ["heart", "love"], rankHint: 9),
                Row(id: ItemID("glyphs", "lantern"), title: "Heart Lantern", rankHint: 5),
                Row(id: ItemID("glyphs", "plain"), title: "Heart", rankHint: 0),
                Row(id: ItemID("glyphs", "pale"), title: "Pale Heart", keywords: ["heart"], rankHint: 3),
                Row(id: ItemID("glyphs", "wood"), title: "Heartwood Leaf", rankHint: 1),
                Row(id: ItemID("glyphs", "pavilion"), title: "Love Pavilion", rankHint: 8),
                Row(id: ItemID("glyphs", "twin"), title: "Twin Hearts", keywords: ["love"], rankHint: 2),
                Row(id: ItemID("glyphs", "stamp"), title: "Kiss Stamp", keywords: ["love"], rankHint: 2),
                Row(id: ItemID("glyphs", "swirl"), title: "Lolly Swirl", rankHint: 7),
                Row(id: ItemID("glyphs", "tearful"), title: "Tearful Grin", keywords: ["lol"], rankHint: 1),
                Row(id: ItemID("glyphs", "rolling"), title: "Rolling Grin", keywords: ["lol"], rankHint: 4),
            ]
            return ListResult(sections: [ListSection("All", rows: rows)])
        }

        func actions(for row: Row) -> [Action] { [] }
    }

    private func titles(for query: String) async throws -> [String] {
        let harness = FeatureHarness(Glyphs.self)
        await harness.activate()
        try await harness.run("open")
        try await harness.setQuery(query)
        return harness.rows.map(\.title)
    }

    @Test func aTitleMatchLeadsItsTierWhateverTheHint() async throws {
        #expect(
            try await titles(for: "heart").prefix(5) == [
                "Heart", "Crimson Heart", "Pale Heart", "Heart Lantern", "Heartwood Leaf",
            ])
    }

    @Test func exactKeywordsLeadTitlesThatOnlyStartWithTheQueryAndFollowTheHint() async throws {
        #expect(
            try await titles(for: "love").prefix(4) == ["Crimson Heart", "Kiss Stamp", "Twin Hearts", "Love Pavilion"],
            "equal hints keep the index's order, which puts the shorter title first")
        #expect(try await titles(for: "lol").prefix(3) == ["Rolling Grin", "Tearful Grin", "Lolly Swirl"])
    }
}
