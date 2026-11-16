import Kit
import Testing

@testable import Host

/// Host filtering reads which field made a match from ``FuzzyMatch/matchesTitle``, not from the
/// highlight ranges. Inside a tier a title match comes first, then the rank hint, then the index's
/// order.
@Suite("Host filter: title matches", .timeLimit(.minutes(1)))
struct HostFilterTests {
    private static let rows = [
        Row(id: ItemID("glyph", "crimson"), title: "Crimson Heart", keywords: ["heart"], rankHint: 9),
        Row(id: ItemID("glyph", "plain"), title: "Heart", rankHint: 0),
        Row(id: ItemID("glyph", "pale"), title: "Pale Heart", keywords: ["heart"], rankHint: 3),
        Row(id: ItemID("glyph", "lantern"), title: "Heart Lantern", rankHint: 5),
        Row(id: ItemID("glyph", "stamp"), title: "Kiss Stamp", keywords: ["heart"], rankHint: 3),
    ]

    private func shown(_ matches: [FuzzyMatch]) -> [HostFilter.Shown] {
        let loaded = [ListSection("All", rows: Self.rows)]
        let filter = HostFilter(positions: HostFilter.entries(for: loaded).positions)
        return filter.filter(loaded, query: "heart", matches: matches)
    }

    @Test func theFlagDecidesWhichMatchIsATitleMatch() {
        // A title match without ranges, and keyword matches that carry ranges anyway.
        let result = shown([
            FuzzyMatch(index: 0, tier: .exact, score: 9, highlights: [8..<13], matchesTitle: false),
            FuzzyMatch(index: 2, tier: .exact, score: 8, highlights: [5..<10], matchesTitle: false),
            FuzzyMatch(index: 1, tier: .exact, score: 7, highlights: [], matchesTitle: true),
            FuzzyMatch(index: 3, tier: .prefix, score: 6, highlights: [0..<5]),
        ])
        #expect(result.map(\.rows) == [[1, 0, 2, 3]], "the title, then the keywords by hint, then the weaker tier")
        #expect(result.first?.highlights == [[], [8..<13], [5..<10], [0..<5]], "ranges stay with their rows")
    }

    @Test func equalHintsKeepTheIndexOrder() {
        let result = shown([
            FuzzyMatch(index: 4, tier: .exact, score: 9, matchesTitle: false),
            FuzzyMatch(index: 2, tier: .exact, score: 8, matchesTitle: false),
        ])
        #expect(result.map(\.rows) == [[4, 2]])
    }
}
