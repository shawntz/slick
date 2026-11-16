import Kit
import KitTesting
import Testing

/// KitTesting's index ranks as the engine's feature index does, so feature tests see the app's order.
@Suite("Fakes: simple fuzzy index", .timeLimit(.minutes(1)))
struct SimpleFuzzyIndexTests {
    /// The titles of the hits for `query`, best first.
    private func titles(_ entries: [FuzzyEntry], _ query: String) -> [String] {
        SimpleFuzzyIndex(entries).search(query, limit: 50).map { entries[$0.index].title }
    }

    @Test func aTitleMatchComesBeforeAKeywordMatchInTheSameTier() {
        let index = SimpleFuzzyIndex([
            FuzzyEntry(title: "Ox", keywords: ["heart"]),
            FuzzyEntry(title: "Heart"),
            FuzzyEntry(title: "Google Chrome"),
            FuzzyEntry(title: "Cal", keywords: ["gcal"]),
        ])
        let heart = index.search("heart", limit: 10)
        #expect(heart.map(\.index) == [1, 0], "the exact title first, though Ox is shorter")
        #expect(heart.map(\.tier) == [.exact, .exact])
        #expect(heart.map(\.matchesTitle) == [true, false])
        #expect(heart[0].score > heart[1].score)
        let gc = index.search("gc", limit: 10)
        #expect(gc.map(\.index) == [2, 3], "an acronym of the title before a keyword that starts with the query")
        #expect(gc.map(\.tier) == [.wordPrefix, .wordPrefix])
        #expect(gc.map(\.matchesTitle) == [true, false])
    }

    @Test func aKeywordMatchHasNoRangesAndATitleMatchHasItsOwn() {
        let index = SimpleFuzzyIndex([
            FuzzyEntry(title: "Red Heart", keywords: ["heart"]),
            FuzzyEntry(title: "Heart Suit"),
        ])
        let matches = index.search("heart", limit: 10)
        #expect(matches.first { $0.index == 1 }?.highlights == [0..<5])
        #expect(matches.first { $0.index == 1 }?.matchesTitle == true)
        #expect(matches.first { $0.index == 0 }?.highlights == [], "the keyword made the match")
        #expect(matches.first { $0.index == 0 }?.matchesTitle == false)
    }

    /// The emoji grid's three cases, on made-up items: the item a feature tagged with the typed word
    /// comes before a title that only starts with it.
    @Test func aKeywordEqualToTheQueryIsExact() {
        let grid = [
            FuzzyEntry(title: "Crimson Heart", keywords: ["heart", "love"]),
            FuzzyEntry(title: "Heart Lantern"),
            FuzzyEntry(title: "Heartwood Leaf"),
            FuzzyEntry(title: "Pale Heart", keywords: ["heart"]),
            FuzzyEntry(title: "Love Pavilion"),
            FuzzyEntry(title: "Twin Hearts", keywords: ["love"]),
            FuzzyEntry(title: "Kiss Stamp", keywords: ["love", "kiss"]),
            FuzzyEntry(title: "Lolly Swirl"),
            FuzzyEntry(title: "Tearful Grin", keywords: ["lol", "laugh"]),
            FuzzyEntry(title: "Rolling Grin", keywords: ["lol"]),
        ]
        #expect(
            titles(grid, "heart").prefix(4) == ["Pale Heart", "Crimson Heart", "Heart Lantern", "Heartwood Leaf"],
            "exact keywords by length, then the title prefixes")
        #expect(titles(grid, "love").prefix(4) == ["Kiss Stamp", "Twin Hearts", "Crimson Heart", "Love Pavilion"])
        #expect(titles(grid, "lol").prefix(3) == ["Tearful Grin", "Rolling Grin", "Lolly Swirl"])
        let love = SimpleFuzzyIndex(grid).search("love", limit: 4)
        #expect(love.map(\.tier) == [.exact, .exact, .exact, .prefix])
        #expect(love.map(\.matchesTitle) == [false, false, false, true])
    }

    @Test func onlyAWholeKeywordMovesAndItFoldsAsATitleDoes() {
        let entries = [
            FuzzyEntry(title: "Love Pavilion"),
            FuzzyEntry(title: "Twin Hearts", keywords: ["lovely"]),
            FuzzyEntry(title: "Coffee Cup", keywords: ["Café"]),
            FuzzyEntry(title: "Cafeteria"),
        ]
        let index = SimpleFuzzyIndex(entries)
        #expect(index.search("love", limit: 5).map(\.tier) == [.prefix, .wordPrefix], "a keyword that starts with it")
        #expect(index.search("CAFE", limit: 5).map(\.index) == [2, 3])
        #expect(index.search("CAFE", limit: 5).first?.tier == .exact)
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
        #expect(match.matchesTitle)
    }
}
