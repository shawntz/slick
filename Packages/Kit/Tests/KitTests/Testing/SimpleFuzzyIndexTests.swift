import Kit
import KitTesting
import Testing

/// KitTesting's index orders inside a tier as the engine does, so feature tests see the app's order.
@Suite("Fakes: simple fuzzy index", .timeLimit(.minutes(1)))
struct SimpleFuzzyIndexTests {
    @Test func aTitleMatchComesBeforeAKeywordMatchInTheSameTier() {
        let index = SimpleFuzzyIndex([
            FuzzyEntry(title: "Red Heart", keywords: ["heart", "love"]),
            FuzzyEntry(title: "Heart Suit"),
            FuzzyEntry(title: "Hearts"),
        ])
        let matches = index.search("heart", limit: 10)
        #expect(matches.map(\.index) == [2, 1, 0], "the shorter Red Heart matched only by keyword")
        #expect(matches.map(\.tier) == [.prefix, .prefix, .prefix])
        #expect(matches[0].score > matches[1].score && matches[1].score > matches[2].score)
    }

    @Test func aKeywordMatchHasNoRangesAndATitleMatchHasItsOwn() {
        let index = SimpleFuzzyIndex([
            FuzzyEntry(title: "Red Heart", keywords: ["heart"]),
            FuzzyEntry(title: "Heart Suit"),
        ])
        let matches = index.search("heart", limit: 10)
        #expect(matches.first { $0.index == 1 }?.highlights == [0..<5])
        #expect(matches.first { $0.index == 0 }?.highlights == [], "the title only matched more weakly")
    }

    @Test(arguments: [
        ("Term", "term", MatchTier.exact, [0..<4]),
        ("Terminal", "term", .prefix, [0..<4]),
        ("Google Chrome", "go chr", .prefix, [0..<2, 7..<10]),
        ("Google Chrome", "gc", .wordPrefix, [0..<1, 7..<8]),
        ("Dark Mode", "mode dark", .unordered, [0..<4, 5..<9]),
        ("Determine", "term", .substring, [2..<6]),
        ("Terminal", "trml", .subsequence, [0..<1, 2..<4, 7..<8]),
    ])
    func everyTitleTierHasItsRanges(title: String, query: String, tier: MatchTier, ranges: [Range<Int>]) throws {
        let match = try #require(SimpleFuzzyIndex([FuzzyEntry(title: title)]).search(query, limit: 1).first)
        #expect(match.tier == tier)
        #expect(match.highlights == ranges)
    }
}
