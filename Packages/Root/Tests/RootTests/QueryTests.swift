import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

@Suite struct QueryTests {
    @Test func sectionsComeInContractOrder() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        let claimed = fixture.root.update(query: "=21")
        #expect(claimed.sections.map(\.kind) == [.answers, .fallbacks])
        #expect(claimed.rows.first?.title == "42")

        let shelf = fixture.root.update(query: "garden atlas")
        #expect(shelf.sections.map(\.kind).last == .fallbacks)
        let kinds = shelf.sections.map(\.kind)
        #expect(kinds.contains(.provider(namespace: "book")))
        if let results = kinds.firstIndex(of: .results),
            let provider = kinds.firstIndex(of: .provider(namespace: "book"))
        {
            #expect(results < provider)
        }
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func anItemAnInstantAnswerShowsIsNotRepeatedInResults() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        // The engine finds Example Book by its title and the instant answer returns the same row:
        // it shows once, in the answer's section.
        let snapshot = fixture.root.update(query: "example book")
        let book = ItemID("book", "1")
        #expect(snapshot.rows.filter { $0.id == book }.count == 1)
        #expect(snapshot.section(containing: book)?.kind == .provider(namespace: "book"))
        #expect(snapshot.section(containing: book)?.title == "On the Shelf")
        await fixture.shutdown()
    }

    @Test func theFirstTwelveRowsCarryHighlightsAndTheRestComeOnRequest() async throws {
        let fixture = await RootFixture.ready(extraSources: [NumberedItems(count: 30)])
        _ = fixture.root.begin()
        let snapshot = fixture.root.update(query: "sample")
        let results = try #require(snapshot.sections.first { $0.kind == .results }?.rows)
        #expect(results.count == 30)
        #expect(results.prefix(12).allSatisfy { $0.titleHighlights == [0..<6] })
        #expect(results.dropFirst(12).allSatisfy { $0.titleHighlights.isEmpty })
        #expect(fixture.root.titleHighlights(for: results[20]) == [0..<6])
        fixture.root.end()
        #expect(fixture.root.titleHighlights(for: results[20]).isEmpty)
        await fixture.shutdown()
    }

    @Test func theCompletionFollowsItsSetting() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        let completion = try #require(fixture.root.update(query: "calen").completion)
        #expect(completion.id == fixture.apps.id("Calendar"))
        #expect(completion.text == "calendar")
        #expect(completion.ghostText(after: "calen") == "dar")

        fixture.general[HostSettings.inlineCompletion] = false
        await fixture.settle()
        #expect(fixture.root.update(query: "calen").completion == nil)
        await fixture.shutdown()
    }

    @Test func fallbacksComeFromTheSettingOrTheFeatures() async throws {
        let fixture = await RootFixture.ready()
        let defaults = try #require(fixture.root.update(query: "zebra").sections.last)
        #expect(defaults.kind == .fallbacks)
        #expect(defaults.title == "Use \"zebra\" with")
        #expect(defaults.rows.map(\.title) == ["Search Library for \"zebra\""])
        #expect(defaults.rows.first?.id == .command(feature: "library", command: "search"))

        fixture.general[HostSettings.fallbackCommands] = ["cmd:garden.water"]
        await fixture.settle()
        _ = fixture.root.begin()
        let none = fixture.root.update(query: "zzqqxx")
        #expect(none.sections.isEmpty)
        // The file provider is still working, so the empty state waits for it.
        #expect(none.isLoading && none.emptyState == nil)
        await fixture.passDebounce()
        #expect(fixture.root.snapshot.emptyState?.title == "No Results")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aBlankQueryShowsTheEmptyState() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        let blank = fixture.root.update(query: "   ")
        #expect(blank.query == "   ")
        #expect(!blank.sections.contains { $0.kind == .results || $0.kind == .fallbacks })
        #expect(blank.emptyState == nil)
        await fixture.shutdown()
    }

    @Test func asyncProviderSectionsArePlannedAndFillInBeforeFallbacks() async throws {
        let fixture = await RootFixture.ready()
        let root = fixture.root
        _ = root.begin()
        _ = root.update(query: "x")
        #expect(root.pendingProviders.isEmpty)
        let typed = root.update(query: "garden")
        #expect(root.pendingProviders.map(\.sectionID) == ["async.file"])
        #expect(typed.isLoading)
        #expect(typed.emptyState == nil)

        let file = Row(id: ItemID("file", "/tmp/garden.txt"), title: "garden.txt")
        let generation = root.queryGeneration
        let signals = root.changes.generation
        #expect(root.deliver([file], title: "Files", at: 0, generation: generation))
        #expect(root.snapshot.sections.map(\.kind).suffix(2) == [.provider(namespace: "file"), .fallbacks])
        #expect(root.snapshot.revision > typed.revision)
        #expect(!root.snapshot.isLoading)
        #expect(root.changes.generation == signals + 1)
        #expect(!root.deliver([file], title: "Files", at: 0, generation: generation))

        _ = root.update(query: "garden a")
        #expect(!root.deliver([file], title: "Files", at: 0, generation: generation))

        let path = root.update(query: "/tmp")
        #expect(path.sections.isEmpty)
        #expect(path.isLoading)
        #expect(root.pendingProviders.map(\.takesOver) == [true])
        await fixture.passDebounce()
        #expect(!root.snapshot.isLoading)
        #expect(root.snapshot.emptyState?.title == "No Results")
        root.end()
        await fixture.shutdown()
    }

    @Test func beforeTheEngineOpensAQueryShowsAnswersAndFallbacks() async throws {
        let fixture = RootFixture()
        #expect(fixture.root.status == .opening)
        _ = fixture.root.begin()
        let early = fixture.root.update(query: "=2")
        #expect(early.sections.map(\.kind) == [.answers, .fallbacks])
        fixture.root.end()
        await fixture.root.ready()
        #expect(fixture.root.status == .ready(persistent: false))
        #expect(fixture.results("calendar") == ["Calendar"])
        await fixture.shutdown()
    }

    @Test func revisionsGrowAndTheSnapshotIsTheLastOne() async throws {
        let fixture = await RootFixture.ready()
        let empty = fixture.root.begin()
        let typed = fixture.root.update(query: "cal")
        #expect(typed.revision > empty.revision)
        #expect(fixture.root.snapshot.revision == typed.revision)
        #expect(fixture.root.snapshot.query == "cal")
        await fixture.shutdown()
    }
}
