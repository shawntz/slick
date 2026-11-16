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

    /// Words whose first emoji is the same whether or not the host puts a name match before a
    /// keyword match inside a tier, so the harness shows them as the app does.
    @Test(arguments: [
        ("thumbs", "Thumbs Up"),
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

    /// The name of an emoji, or the start of it, finds that emoji first when it is the most used of
    /// the emoji with that name. A name match comes before a keyword match inside a tier.
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

    @Test(arguments: names)
    func aNameFindsItsEmojiFirstInTheGrid(query: String, expected: String) {
        let titles = gridOrder(query).prefix(5).map(\.title)
        #expect(titles.first == expected, "\(query): \(titles)")
    }

    @Test(arguments: names)
    func aNameFindsItsEmojiFirstAfterAColon(query: String, expected: String) async throws {
        let harness = await loadedHarness()
        let rows = harness.instantAnswers(for: ":" + query).first?.rows ?? []
        #expect(rows.first?.title == expected, "\(query): \(rows.map(\.title))")
    }

    /// Every emoji named Grinning comes before Beaming Face with Smiling Eyes, which only has the
    /// keyword, and the most used of them comes first.
    @Test func grinningListsTheGrinningFacesBeforeKeywordMatches() async throws {
        let titles = gridOrder("grinning").map(\.title)
        let beaming = try #require(titles.firstIndex(of: "Beaming Face with Smiling Eyes"))
        let named = [
            "Grinning Face with Sweat", "Grinning Squinting Face", "Grinning Face with Big Eyes",
            "Grinning Face with Smiling Eyes", "Grinning Face",
        ]
        #expect(Array(titles.prefix(named.count)) == named, "the most used first: \(titles.prefix(6))")
        #expect(beaming > named.count)
        let harness = await loadedHarness()
        let colon = harness.instantAnswers(for: ":grinning").first?.rows.map(\.title) ?? []
        #expect(colon.prefix(named.count) == named[...], "\(colon)")
    }

    /// A match on the name beats a match on a keyword alone in the same tier, even for the emoji
    /// people use most: the host's rule for every list it filters.
    @Test(arguments: [("heart", "Red Heart"), ("pray", "Folded Hands"), ("sad", "Loudly Crying Face")])
    func aNameMatchBeatsTheMostUsedKeywordMatch(query: String, keywordOnly: String) throws {
        let rows = gridOrder(query)
        let first = try #require(rows.first)
        #expect(matchesByTitle(first, query), "\(query): \(first.title)")
        let keyword = try #require(rows.firstIndex { $0.title == keywordOnly })
        #expect(!matchesByTitle(rows[keyword], query))
        #expect(rows.prefix(keyword).allSatisfy { matchesByTitle($0, query) }, "\(query)")
    }

    /// Among keyword matches the emoji people use most comes first.
    @Test(arguments: [("laugh", "Face with Tears of Joy"), ("lol", "Face with Tears of Joy")])
    func theMostUsedEmojiLeadTheKeywordMatches(query: String, expected: String) {
        let keywordOnly = gridOrder(query).filter { !matchesByTitle($0, query) }
        #expect(keywordOnly.first?.title == expected, "\(query): \(keywordOnly.prefix(4).map(\.title))")
    }

    /// The colon search orders as the grid does: by tier, then a name before a keyword, then use.
    @Test(arguments: ["grinning", "heart", "love", "laugh", "party", "smile", "cat", "sad"])
    func theColonSearchOrdersAsTheGridDoes(query: String) async throws {
        let harness = await loadedHarness()
        let colon = harness.instantAnswers(for: ":" + query).first?.rows.map(\.title) ?? []
        #expect(!colon.isEmpty)
        #expect(Array(gridOrder(query).prefix(colon.count).map(\.title)) == colon, "\(query)")
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

    /// Words whose best match does not depend on the host's name-first rule, through the harness.
    @Test(arguments: ["thumbs", "smile", "laugh", "cat", "party", "check", "euro", "command"])
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
