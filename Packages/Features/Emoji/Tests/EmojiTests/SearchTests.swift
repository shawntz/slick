import Kit
import KitTesting
import Testing

@testable import Emoji

@Suite("Search", .timeLimit(.minutes(1)))
struct SearchTests {
    @Test func theGridShowsGroupsInOrderWhenNothingIsTyped() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        let titles = harness.sections.map(\.title)
        #expect(titles.first == "Smileys & Emotion", "no Recently Used section before any use")
        #expect(titles.prefix(9) == EmojiGroup.allCases.prefix(9).map { EmojiStrings.groupTitle($0) }[...])
        #expect(titles.last == "Box Drawing")
        #expect(harness.selectedRow?.title == "Grinning Face")
        guard case .grid(let page) = harness.page?.page else {
            Issue.record("the command did not push a grid")
            return
        }
        #expect(page.columns == 8 && !page.showsTitles)
        #expect(harness.issues.isEmpty)
    }

    /// Common words and the emoji the grid shows first for each. Only Thumbs Down has the keyword
    /// "thumbs", and a keyword equal to the query is in the exact tier, above Thumbs Up's name,
    /// which only starts with it.
    @Test(arguments: [
        ("thumbs", "Thumbs Down"),
        ("cat", "Cat"),
        ("fire", "Fire"),
        ("laugh", "Face with Tears of Joy"),
        ("party", "Party Popper"),
        ("check", "Check Mark Button"),
        ("euro", "Euro"),
        ("command", "Command Key"),
    ])
    func commonWordsFindTheExpectedEmojiFirst(query: String, expected: String) async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery(query)
        #expect(harness.sections.count == 1, "while searching, one section ranks every match")
        #expect(harness.titles(1) == [expected], "\(query): \(harness.titles(5))")
    }

    /// The name of an emoji, or the start of it, finds that emoji first in the colon search when it
    /// is the most used of the emoji with that name.
    nonisolated static let names: [(String, String)] = [
        ("unamused", "Unamused Face"),
        ("expressionless", "Expressionless Face"),
        ("disappointed", "Disappointed Face"),
        ("thinking", "Thinking Face"),
        ("winking", "Winking Face"),
        ("pleading", "Pleading Face"),
        ("thumbs", "Thumbs Up"),
        ("folded", "Folded Hands"),
        ("clapping", "Clapping Hands"),
        ("christmas", "Christmas Tree"),
        ("birthday", "Birthday Cake"),
        ("red heart", "Red Heart"),
        ("party", "Party Popper"),
        ("crying", "Crying Face"),
    ]

    /// The grid's first emoji for the same words. A keyword equal to the query is in the exact tier,
    /// and inside that tier keyword matches follow use. So where a more used emoji has the word as a
    /// keyword, it comes before the emoji whose name only starts with the word.
    nonisolated static let gridFirsts: [(String, String)] = [
        ("unamused", "Neutral Face"),
        ("expressionless", "Neutral Face"),
        ("disappointed", "Pensive Face"),
        ("thinking", "Thinking Face"),
        ("winking", "Winking Face"),
        ("pleading", "Pleading Face"),
        ("thumbs", "Thumbs Down"),
        ("folded", "Folded Hands"),
        ("clapping", "Clapping Hands"),
        ("christmas", "Wrapped Gift"),
        ("birthday", "Party Popper"),
        ("red heart", "Red Heart"),
        ("party", "Party Popper"),
        ("crying", "Face with Tears of Joy"),
    ]

    @Test(arguments: gridFirsts)
    func aWordFindsTheExpectedEmojiFirstInTheGrid(query: String, expected: String) async throws {
        let titles = try await gridTitles(query).prefix(5)
        #expect(titles.first == expected, "\(query): \(titles)")
    }

    @Test(arguments: names)
    func aNameFindsItsEmojiFirstAfterAColon(query: String, expected: String) async throws {
        let harness = await loadedHarness()
        let rows = harness.instantAnswers(for: ":" + query).first?.rows ?? []
        #expect(rows.first?.title == expected, "\(query): \(rows.map(\.title))")
    }

    /// Every emoji named Grinning also has the keyword, so in the grid all six are exact keyword
    /// matches ordered by use: Beaming Face with Smiling Eyes, the most used, first. The colon search
    /// still lists the five named Grinning first.
    @Test func grinningListsTheGrinningFacesByUse() async throws {
        let titles = try await gridTitles("grinning")
        let named = [
            "Grinning Face with Sweat", "Grinning Squinting Face", "Grinning Face with Big Eyes",
            "Grinning Face with Smiling Eyes", "Grinning Face",
        ]
        #expect(Array(titles.prefix(6)) == ["Beaming Face with Smiling Eyes"] + named, "\(titles.prefix(6))")
        let harness = await loadedHarness()
        let colon = harness.instantAnswers(for: ":grinning").first?.rows.map(\.title) ?? []
        #expect(colon.prefix(named.count) == named[...], "\(colon)")
    }

    /// A keyword equal to the query is an exact match, so the emoji people use most with that
    /// keyword comes before every emoji whose name only starts with the word or holds it later.
    @Test(arguments: [("heart", "Red Heart"), ("pray", "Folded Hands"), ("sad", "Loudly Crying Face")])
    func theMostUsedExactKeywordMatchLeads(query: String, keywordOnly: String) async throws {
        let rows = try await gridRows(query)
        let first = try #require(rows.first)
        #expect(first.title == keywordOnly, "\(query): \(rows.prefix(4).map(\.title))")
        #expect(!matchesByTitle(first, query), "the keyword made the match")
    }

    /// Among keyword matches the emoji people use most comes first.
    @Test(arguments: [("laugh", "Face with Tears of Joy"), ("lol", "Face with Tears of Joy")])
    func theMostUsedEmojiLeadTheKeywordMatches(query: String, expected: String) async throws {
        let keywordOnly = try await gridRows(query).filter { !matchesByTitle($0, query) }
        #expect(keywordOnly.first?.title == expected, "\(query): \(keywordOnly.prefix(4).map(\.title))")
    }

    /// For these words the colon search orders as the grid does. It ranks a keyword equal to the
    /// query one tier below an exact name and puts a name before a keyword inside a tier, so for
    /// words such as "heart", "grinning" and "thumbs" the two now differ.
    @Test(arguments: ["laugh", "party", "smile"])
    func theColonSearchOrdersAsTheGridDoes(query: String) async throws {
        let harness = await loadedHarness()
        let colon = harness.instantAnswers(for: ":" + query).first?.rows.map(\.title) ?? []
        let grid = try await gridTitles(query)
        #expect(!colon.isEmpty)
        #expect(Array(grid.prefix(colon.count)) == colon, "\(query)")
    }

    @Test func theScoreFollowsUse() throws {
        let joy = try entry("😂")
        let heart = try entry("❤️")
        let grinning = try entry("😀")
        let beaming = try entry("😁")
        let grinningCat = try entry("😺")
        #expect(EmojiRanking.staticScore(joy) > EmojiRanking.staticScore(heart))
        #expect(EmojiRanking.staticScore(heart) > EmojiRanking.staticScore(beaming))
        #expect(EmojiRanking.staticScore(beaming) > EmojiRanking.staticScore(grinning))
        #expect(EmojiRanking.staticScore(grinning) > EmojiRanking.staticScore(grinningCat))
        #expect(EmojiRanking.staticScore(grinningCat) == 0, "an emoji outside the common list")
        #expect(EmojiRanking.score(grinningCat, frecency: 1) > EmojiRanking.staticScore(joy), "a use wins")
    }

    @Test func smileFindsSmilingFacesBeforeAnythingElse() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("smile")
        let top = harness.rows.prefix(8)
        #expect(top.count == 8)
        let groups = try top.map { try #require(bundledCatalog.entry(forKey: $0.id.key)).group }
        #expect(groups.allSatisfy { $0 == .smileys }, "\(harness.titles(8))")
    }

    @Test func theIndexIsBuiltOncePerLoad() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        for query in ["h", "he", "hea", "heart", ""] { try await harness.setQuery(query) }
        #expect(harness.fakes.fuzzyIndex.builtIndexSizes.count == 1)
    }

    @Test func theCategoryDropdownNarrowsTheGrid() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        let dropdown = try #require(harness.page?.dropdown)
        #expect(dropdown.options.first?.title == "All Categories")
        #expect(dropdown.options.count == EmojiGroup.allCases.count + 1)
        try await harness.setFilter("animals")
        #expect(harness.sections.map(\.title) == ["Animals & Nature"])
        try await harness.setQuery("cat")
        #expect(harness.titles(1) == ["Cat"])
        try await harness.setQuery("heart")
        #expect(!harness.titles().contains("Red Heart"), "outside the category")
    }

    @Test func symbolsCanBeLeftOut() async throws {
        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.includeSymbols] = false
        try await harness.run("search")
        #expect(harness.sections.last?.title == "Flags")
        #expect(harness.page?.dropdown?.options.count == 10)
        try await harness.setQuery("euro")
        #expect(harness.titles(3).contains("Euro Banknote"))
        #expect(!harness.titles().contains("Euro"), "the euro sign is a symbol")
        let colon = harness.instantAnswers(for: ":euro").first?.rows.map(\.title) ?? []
        #expect(!colon.isEmpty && !colon.contains("Euro"))
    }

    @Test func emptyResultsShowTheEmptyState() async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery("zzzqqq")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == EmojiStrings.noMatchesTitle)
    }

    // MARK: Colon search in root

    @Test func colonSearchAnswersAtTheTopOfRoot() async throws {
        let harness = await loadedHarness()
        let answer = try #require(harness.instantAnswers(for: ":smile").first)
        #expect(answer.claimsTop)
        #expect(answer.rows.count == ColonSearch.maximumRows)
        #expect(answer.rows.allSatisfy { $0.id.namespace == "emoji" && $0.memory == .learnOnly })
        #expect(answer.rows.first?.subtitle == "Emoji")
    }

    @Test(arguments: [
        (":red heart", "Red Heart"),
        (":thumbs up", "Thumbs Up"),
        (":thumbs", "Thumbs Up"),
        (":thu", "Thumbs Up"),
        (":rocket", "Rocket"),
        (":cat", "Cat"),
        (":laugh", "Face with Tears of Joy"),
        (":smile:", "Smiling Face with Hearts"),
        (":Flag: United States", "Flag: United States"),
        (":tears joy", "Face with Tears of Joy"),
        (":pinata", "Piñata"),
        (":euro", "Euro"),
    ])
    func colonSearchRanksCommonWords(query: String, expected: String) async throws {
        let harness = await loadedHarness()
        let rows = harness.instantAnswers(for: query).first?.rows ?? []
        #expect(rows.first?.title == expected, "\(query): \(rows.map(\.title))")
    }

    /// Words whose best match is the same in the grid and the colon search.
    @Test(arguments: ["smile", "laugh", "cat", "party", "check", "euro", "command"])
    func colonSearchAndTheGridAgreeOnTheBestMatch(word: String) async throws {
        let harness = await loadedHarness()
        try await harness.run("search")
        try await harness.setQuery(word)
        let colon = harness.instantAnswers(for: ":" + word).first?.rows.first
        #expect(colon?.id == harness.rows.first?.id, "\(word): \(colon?.title ?? "nothing") and \(harness.titles(1))")
    }

    @Test(arguments: ["smile", "", ":", ":s", ": smile", "::", ":)", "safari", "12 * 3", "/Users", "~/", ":zzzqqq"])
    func colonSearchIgnoresQueriesThatAreNotItsOwn(query: String) async throws {
        let harness = await loadedHarness()
        #expect(harness.instantAnswers(for: query).isEmpty)
    }

    @Test func colonSearchWaitsForTheDataAndCanBeTurnedOff() async throws {
        let cold = FeatureHarness(EmojiFeature.self)
        #expect(cold.instantAnswers(for: ":smile").isEmpty, "nothing before activation")

        let harness = await loadedHarness()
        harness.context.settings[EmojiSettings.colonSearch] = false
        #expect(harness.instantAnswers(for: ":smile").isEmpty)
        harness.context.settings[EmojiSettings.colonSearch] = true
        #expect(!harness.instantAnswers(for: ":smile").isEmpty)
    }

    @Test func colonRowsPasteFromRootAndRootRecordsTheUse() async throws {
        let harness = await loadedHarness()
        let row = try #require(harness.instantAnswers(for: ":rocket").first?.rows.first)
        try await harness.performRoot("paste", on: row, query: ":rocket")
        #expect(harness.fakes.pasteboard.pastedTexts == ["🚀"])
        #expect(harness.fakes.usage.recorded.isEmpty, "root records uses of its own rows")
        #expect(harness.issues.isEmpty)
    }
}
