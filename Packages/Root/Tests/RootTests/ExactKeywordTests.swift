import Kit
import Testing

@testable import Root

/// The engine's feature index puts a keyword equal to the query in the exact tier and marks such a
/// match as a keyword match, so the host lists it after an exact title and before any title that
/// only starts with the query. All items are made up.
@Suite("Engine fuzzy index: exact keywords", .timeLimit(.minutes(1)))
struct ExactKeywordTests {
    private static let grid = [
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

    private func titles(_ matches: [FuzzyMatch]) -> [String] {
        matches.map { Self.grid[$0.index].title }
    }

    @Test func heartLoveAndLolListTheTaggedItemsFirst() async {
        let index = await EngineFuzzyIndexService().makeIndex(Self.grid)
        let heart = index.search("heart", limit: 10)
        #expect(titles(heart).prefix(4) == ["Pale Heart", "Crimson Heart", "Heart Lantern", "Heartwood Leaf"])
        #expect(heart.prefix(4).map(\.tier) == [.exact, .exact, .prefix, .prefix])
        let love = index.search("love", limit: 10)
        #expect(titles(love).prefix(4) == ["Kiss Stamp", "Twin Hearts", "Crimson Heart", "Love Pavilion"])
        let lol = index.search("lol", limit: 10)
        #expect(titles(lol).prefix(3) == ["Tearful Grin", "Rolling Grin", "Lolly Swirl"])
        #expect(lol.prefix(3).map(\.tier) == [.exact, .exact, .prefix])
    }

    @Test func aKeywordMatchSaysSoAndATitleMatchKeepsItsRanges() async throws {
        let index = await EngineFuzzyIndexService().makeIndex(Self.grid)
        let love = index.search("love", limit: 10)
        #expect(love.prefix(4).map(\.matchesTitle) == [false, false, false, true])
        #expect(love.prefix(3).allSatisfy { $0.highlights.isEmpty })
        #expect(love[3].highlights == [0..<4])
        let lantern = try #require(index.search("lantern", limit: 1).first)
        #expect(lantern.matchesTitle && lantern.highlights == [6..<13])
    }

    @Test func anExactTitleStillLeadsAndOnlyAWholeKeywordMoves() async {
        let index = await EngineFuzzyIndexService().makeIndex([
            FuzzyEntry(title: "Ox", keywords: ["heart"]),
            FuzzyEntry(title: "Heart"),
            FuzzyEntry(title: "Hearth Rug"),
            FuzzyEntry(title: "Pulse", keywords: ["hearty"]),
        ])
        let heart = index.search("heart", limit: 10)
        #expect(heart.map(\.index) == [1, 0, 2, 3], "the exact title, the exact keyword, a prefix, a keyword prefix")
        #expect(heart.map(\.tier) == [.exact, .exact, .prefix, .wordPrefix])
        #expect(heart.map(\.matchesTitle) == [true, false, true, false])
    }
}
