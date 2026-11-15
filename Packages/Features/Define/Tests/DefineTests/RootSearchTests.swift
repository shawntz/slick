import Foundation
import Kit
import KitTesting
import Testing

@testable import Define

@Suite("Root search", .timeLimit(.minutes(1)))
struct RootSearchTests {
    @Test func theDefineKeywordShowsTheEntryAlone() async throws {
        let harness = makeHarness()
        let provider = harness.feature.provider
        #expect(provider.takesOver("define lantern"))
        #expect(provider.sectionTitle(for: "define lantern") == "Definition")
        #expect(provider.debounce(for: "define lantern") == KeywordProvider.keywordDebounce)
        let sections = try await harness.asyncSections(for: "Define lantern")
        #expect(sections.map(\.title) == ["Definition"])
        let row = try #require(sections.first?.rows.first)
        #expect(row.title == "lantern")
        #expect(row.subtitle == "a lamp in a case with clear sides that keeps the wind from the flame")
        #expect(row.memory == .never)
        #expect(row.represents == .text("lantern"))
        #expect(
            harness.rootActions(for: row).map(\.id) == [
                "show-definition", "copy-definition", "paste-definition", "open-in-dictionary", "copy-word",
            ])
        try await harness.performRoot("show-definition", on: row)
        #expect(harness.pageTitle == "lantern")
        #expect(harness.issues.isEmpty)
    }

    @Test func copyDefinitionFromARootRowLooksTheEntryUpWhenItRuns() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        let row = try #require(try await harness.asyncSections(for: "define harbor").first?.rows.first)
        try await harness.performRoot("copy-definition", on: row)
        #expect(harness.fakes.pasteboard.copiedTexts.first?.hasPrefix("harbor\nhar·bor  | ˈhärbər |") == true)
        #expect(harness.huds == ["Copied Definition"])
        #expect(lookup.recorded == ["definition:harbor", "definition:harbor"])
    }

    @Test func defineAMisspellingSuggestsSpellings() async throws {
        let harness = makeHarness()
        let sections = try await harness.asyncSections(for: "define lantren")
        let rows = sections.flatMap(\.rows)
        #expect(rows.map(\.title) == ["lantern", "lanterns"])
        #expect(rows.allSatisfy { $0.subtitle == "Suggested spelling" })
        try await harness.performRoot("show-definition", on: rows[0])
        #expect(harness.pageTitle == "lantern")
    }

    @Test func theSpellKeywordListsSpellings() async throws {
        let harness = makeHarness()
        let provider = harness.feature.provider
        #expect(provider.takesOver("spell recieve"))
        #expect(provider.sectionTitle(for: "spell recieve") == "Spelling")
        let sections = try await harness.asyncSections(for: "spell recieve")
        let rows = sections.flatMap(\.rows)
        #expect(rows.map(\.title) == ["recieve", "receive", "relieve"])
        try await harness.performRoot("copy-word", on: rows[1])
        #expect(harness.fakes.pasteboard.copiedTexts == ["receive"])
        #expect(try await harness.asyncSections(for: "spell ice cream").isEmpty)
    }

    @Test func theKeywordsCanBeTurnedOff() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        harness.context.settings[DefineSettings.keywords] = false
        let provider = harness.feature.provider
        #expect(!provider.takesOver("define lantern"))
        #expect(!provider.takesOver("spell recieve"))
        #expect(try await harness.asyncSections(for: "define lantern").isEmpty)
        #expect(lookup.recorded.isEmpty)
    }

    @Test func aSingleWordIsNotLookedUpUnlessTheSettingIsOn() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        #expect(!harness.feature.provider.takesOver("lantern"))
        #expect(try await harness.asyncSections(for: "lantern").isEmpty)
        #expect(lookup.recorded.isEmpty)
    }

    @Test func withTheSettingOnASingleWordGetsItsEntryUnderOtherResults() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        harness.context.settings[DefineSettings.singleWords] = true
        let provider = harness.feature.provider
        #expect(!provider.takesOver("lantern"))
        #expect(provider.debounce(for: "lantern") == KeywordProvider.singleWordDebounce)
        let sections = try await harness.asyncSections(for: "lantern")
        #expect(sections.map(\.title) == ["Dictionary"])
        #expect(sections.first?.rows.map(\.title) == ["lantern"])
        // An entry found for another word that lists this one is left out.
        #expect(try await harness.asyncSections(for: "harbour").isEmpty)
        #expect(try await harness.asyncSections(for: "lanterns").isEmpty)
        // Phrases, numbers and paths are never looked up.
        for query in ["ice cream", "safari 2", "~/Documents", ":smile", "ab"] {
            #expect(try await harness.asyncSections(for: query).isEmpty, "\(query)")
        }
        #expect(lookup.recorded == ["definition:lantern", "definition:harbour", "definition:lanterns"])
    }

    @Test(arguments: ["safari", "~/Documents", "/usr", ":smile", "=1+1", "d", "spellbook", "definitely"])
    func otherQueriesAreNotClaimed(query: String) {
        let harness = makeHarness()
        #expect(!harness.feature.provider.takesOver(query))
        #expect(harness.feature.provider.sectionTitle(for: query) == "Dictionary")
    }
}

@Suite("Cancellation", .timeLimit(.minutes(1)))
struct CancellationTests {
    /// Root search cancels a provider's task when the query changes. The lookup that was running
    /// finishes, but its answer is thrown away and the next query answers.
    @Test func aRootLookupCancelledByANewQueryReturnsNothing() async throws {
        let lookup = RecordingLookup(holdsCalls: true)
        let harness = makeHarness(lookup)
        let provider = harness.feature.provider
        let stale = Task { try await provider.results(for: "define lant") }
        #expect(await nextCall(lookup) == "definition:lant")
        stale.cancel()
        await lookup.open()
        let outcome = await stale.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        let rows = try await provider.results(for: "define lantern")
        #expect(rows.map(\.title) == ["lantern"])
        // The stale query never went on to ask for spellings.
        #expect(lookup.recorded == ["definition:lant", "definition:lantern"])
    }

    /// A list page that filters itself is loaded in a task the host cancels when the query
    /// changes. The cancelled load throws instead of returning rows for the old query.
    @Test func aListLoadCancelledByANewQueryNeverShows() async throws {
        let lookup = RecordingLookup(holdsCalls: true)
        let harness = makeHarness(lookup)
        try await harness.run("spell")
        guard case .list(let page) = harness.page?.page else {
            Issue.record("Check Spelling did not open a list")
            return
        }
        let source = page.source
        let stale = Task { try await source.load(ListRequest(query: "recie", reason: .query)) }
        #expect(await nextCall(lookup) == "spelling:recie")
        stale.cancel()
        await lookup.open()
        let outcome = await stale.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        let fresh = try await source.load(ListRequest(query: "recieve", reason: .query))
        #expect(fresh.sections.flatMap(\.rows).map(\.title) == ["recieve", "receive", "relieve"])
    }

    /// The define page's detail is loaded after the selection settles and cancelled when it moves.
    @Test func aDetailCancelledBySelectingAnotherRowReturnsNothing() async throws {
        let lookup = RecordingLookup(holdsCalls: true)
        let harness = makeHarness(lookup)
        let pages = harness.feature.pages
        guard case .list(let page) = pages.lookupList(initialQuery: "") else {
            Issue.record("Define Word did not make a list")
            return
        }
        let row = WordRows.suggestions(["lantern"])[0]
        let stale = Task { try await page.source.detail(for: row) }
        #expect(await nextCall(lookup) == "definition:lantern")
        stale.cancel()
        await lookup.open()
        let outcome = await stale.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test func aLookupInACancelledTaskThrows() async throws {
        let lookup = RecordingLookup()
        let service = Lookup(service: lookup)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.definition(of: LookupTerm.make("lantern")!)
        }
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}
