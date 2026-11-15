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

    @Test(arguments: [
        ("heart", "Red Heart"),
        ("thumbs", "Thumbs Up"),
        ("cat", "Cat"),
        ("fire", "Fire"),
        ("laugh", "Face with Tears of Joy"),
        ("love", "Red Heart"),
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

    /// The name of a common emoji, or the start of it, finds that emoji first: a name that starts
    /// with the query beats an emoji that only has the query as a keyword.
    nonisolated static let names: [(String, String)] = [
        ("grinning", "Grinning Face"),
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

    @Test func grinningListsTheGrinningFacesBeforeKeywordMatches() async throws {
        let titles = gridOrder("grinning").map(\.title)
        let beaming = try #require(titles.firstIndex(of: "Beaming Face with Smiling Eyes"))
        for name in [
            "Grinning Face", "Grinning Face with Big Eyes", "Grinning Squinting Face", "Grinning Face with Sweat",
        ] {
            #expect(try #require(titles.firstIndex(of: name)) < beaming, "\(titles.prefix(8))")
        }
        let harness = await loadedHarness()
        let colon = harness.instantAnswers(for: ":grinning").first?.rows.map(\.title) ?? []
        #expect(colon.prefix(5).allSatisfy { $0.hasPrefix("Grinning") }, "\(colon)")
    }

    /// The ten most used emoji keep their keywords on top, so the words people type for them still
    /// work.
    @Test(arguments: [
        ("heart", "Red Heart"), ("love", "Red Heart"), ("pray", "Folded Hands"), ("laugh", "Face with Tears of Joy"),
    ])
    func theMostUsedEmojiKeepTheirKeywords(query: String, expected: String) {
        #expect(gridOrder(query).first?.title == expected)
    }

    @Test func theScoreRanksTheMostUsedThenCommonThenTheRest() throws {
        let joy = try entry("😂")
        let heart = try entry("❤️")
        let grinning = try entry("😀")
        let beaming = try entry("😁")
        let grinningCat = try entry("😺")
        #expect(EmojiRanking.staticScore(joy) > EmojiRanking.staticScore(heart))
        #expect(EmojiRanking.staticScore(heart) > EmojiRanking.staticScore(beaming))
        #expect(EmojiRanking.staticScore(grinning) == EmojiRanking.staticScore(beaming), "the matcher decides")
        #expect(EmojiRanking.staticScore(beaming) > EmojiRanking.staticScore(grinningCat))
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
        (":heart", "Red Heart"),
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

    @Test(arguments: ["heart", "thumbs", "smile", "laugh", "cat", "party", "check", "euro", "command"])
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
