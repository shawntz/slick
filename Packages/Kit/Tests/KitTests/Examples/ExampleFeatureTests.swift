import Foundation
import Kit
import KitTesting
import Testing

@Suite("Example: UUID")
struct UUIDFeatureTests {
    @Test func copiesAUUIDAndCloses() async throws {
        let harness = FeatureHarness(UUIDFeature.self)
        #expect(harness.issues.isEmpty)
        try await harness.run("copy-uuid")
        let copied = try #require(harness.fakes.pasteboard.copiedTexts.first)
        #expect(UUID(uuidString: copied) != nil)
        #expect(harness.huds == ["Copied UUID"])
        #expect(harness.isClosed)
    }
}

@Suite("Example: HTTP status codes")
struct HTTPStatusFeatureTests {
    @Test func listsEveryStatusInClassSections() async throws {
        let harness = FeatureHarness(HTTPStatusFeature.self)
        #expect(harness.issues.isEmpty)
        try await harness.run("search")
        #expect(harness.sections.map(\.title) == ["2xx", "3xx", "4xx", "5xx"])
        #expect(harness.rows.count == HTTPStatusList.statuses.count)
        #expect(harness.selectedRow?.title == "200 OK")
    }

    @Test func hostFiltersByTitleAndMeaningWithOneIndex() async throws {
        let harness = FeatureHarness(HTTPStatusFeature.self)
        try await harness.run("search")
        try await harness.setQuery("not found")
        #expect(harness.rows.map(\.title) == ["404 Not Found"])
        try await harness.setQuery("30")
        #expect(harness.sections.map(\.title) == ["3xx"], "empty sections are hidden")
        try await harness.setQuery("teapot")
        #expect(harness.rows.map(\.title) == ["418 I'm a Teapot"])
        try await harness.setQuery("rate limited")
        #expect(harness.rows.map(\.title) == ["429 Too Many Requests"])
        // The source loaded once; every keystroke went to the same index.
        #expect(harness.fakes.fuzzyIndex.builtIndexSizes == [HTTPStatusList.statuses.count])
    }

    @Test func copiesTheCodeAndShowsADetail() async throws {
        let harness = FeatureHarness(HTTPStatusFeature.self)
        try await harness.run("search")
        try harness.select(title: "404 Not Found")
        let detail = try #require(try await harness.loadDetail())
        #expect(detail.body == .markdown("# 404 Not Found\n\nThe server has nothing at this URL."))
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.copiedTexts == ["404"])
        #expect(harness.huds == ["Copied to Clipboard"])
    }
}

@Suite("Example: Bookmarks")
struct BookmarksFeatureTests {
    private func activated(_ fakes: FakeServices = FakeServices()) async -> FeatureHarness<BookmarksFeature> {
        let harness = FeatureHarness(BookmarksFeature.self, fakes: fakes)
        await harness.activate()
        return harness
    }

    private func add(_ harness: FeatureHarness<BookmarksFeature>, _ name: String, _ link: String, pinned: Bool = false)
        async throws
    {
        try await harness.run("add")
        try harness.fill("name", text: name)
        try harness.fill("link", text: link)
        try harness.fill("pinned", .bool(pinned))
        try await harness.submit()
    }

    @Test func declaresNothingInvalid() async {
        #expect(await activated().issues.isEmpty)
    }

    @Test func addsThroughTheFormAndSavesToDisk() async throws {
        let fakes = FakeServices()
        let harness = await activated(fakes)
        try await add(harness, "Docs", "https://docs.example.com")
        #expect(harness.pages.isEmpty, "the form pops after saving")
        #expect(harness.toasts.map(\.title) == ["Added Bookmark"])
        let file = fakes.storage.dataDirectory(for: "bookmarks").appending(path: "bookmarks.json")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("https://docs.example.com"))
        #expect(try await harness.catalogRows().map(\.title) == ["Docs"])
    }

    @Test func formRejectsMissingAndBadValues() async throws {
        let harness = await activated()
        try await harness.run("add")
        await #expect(throws: HarnessError.invalidForm(["name": "Required", "link": "Required"])) {
            try await harness.submit()
        }
        try harness.fill("name", text: "Docs")
        try harness.fill("link", text: "docs.example.com")
        await #expect(throws: HarnessError.invalidForm(["link": "Enter a full link, such as https://example.com"])) {
            try await harness.submit()
        }
        try harness.fill("link", text: "https://docs.example.com/{date offset=\"soon\"}")
        await #expect(throws: HarnessError.self) { try await harness.submit() }
        #expect(harness.page?.formErrors["link"]?.range == 25..<45, "the error points at the broken placeholder")
    }

    @Test func listsPinnedFirstAndFilters() async throws {
        let harness = await activated()
        try await add(harness, "Wiki", "https://wiki.example.com")
        try await add(harness, "Docs", "https://docs.example.com", pinned: true)
        try await harness.run("search")
        #expect(harness.sections.map(\.title) == ["Pinned", "Bookmarks"])
        #expect(harness.rows.map(\.title) == ["Docs", "Wiki"])
        try await harness.setFilter("pinned")
        #expect(harness.rows.map(\.title) == ["Docs"])
    }

    @Test func settingsChangeTheOrderOfAnOpenList() async throws {
        let harness = await activated()
        try await add(harness, "Beta", "https://b.example.com")
        harness.fakes.clock.advance(by: .seconds(60))
        try await add(harness, "Alpha", "https://a.example.com")
        try await harness.run("search")
        #expect(harness.rows.map(\.title) == ["Alpha", "Beta"])
        harness.context.settings[BookmarkSettings.order] = .newest
        try await harness.waitForChange()
        #expect(harness.rows.map(\.title) == ["Alpha", "Beta"])
        harness.context.settings[BookmarkSettings.pinnedFirst] = false
        harness.context.settings[BookmarkSettings.order] = .name
        try await harness.settle()
        #expect(harness.sections.map(\.title) == [nil])
        #expect(harness.feature.settingsPane?.sections.first?.items.count == 2)
    }

    @Test func deleteAsksFirst() async throws {
        let harness = await activated()
        try await add(harness, "Docs", "https://docs.example.com")
        try await harness.run("search")
        harness.confirmationAnswer = false
        try await harness.perform("delete")
        #expect(harness.rows.count == 1)
        harness.confirmationAnswer = true
        try await harness.perform("delete")
        #expect(harness.confirmations.map(\.title) == ["Delete \"Docs\"?", "Delete \"Docs\"?"])
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Bookmarks")
    }

    @Test func pasteNeedsAccessibilityAndNeverPromptsBySurprise() async throws {
        let harness = await activated()
        try await add(harness, "Docs", "https://docs.example.com")
        harness.fakes.permissions.set(.accessibility, to: .notDetermined)
        try await harness.run("search")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) { try await harness.perform("paste") }
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.pasteboard.pasted.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.perform("paste")
        #expect(harness.fakes.permissions.requests == [.accessibility])
        #expect(harness.fakes.pasteboard.pastedTexts == ["https://docs.example.com"])
    }

    @Test func argumentBookmarksBecomeCommandsWithInlineArguments() async throws {
        let harness = await activated()
        try await add(harness, "Search Docs", "https://docs.example.com/search?q={argument name=\"query\"}")
        let command = try #require(harness.feature.commands.first { $0.title == "Search Docs" })
        #expect(command.arguments.map(\.name) == ["query"])
        try await harness.run(command.id, arguments: ["query": "kit & glass"])
        #expect(harness.fakes.workspace.opened == [URL(string: "https://docs.example.com/search?q=kit%20%26%20glass")])
        await #expect(throws: HarnessError.missingArgument("query")) { try await harness.run(command.id) }
        #expect(try harness.rowActions(ofCommand: command.id).map(\.id) == ["copy", "pin", "delete"])
    }

    @Test func fallbackOpensTheListWithTheTypedText() async throws {
        let harness = await activated()
        try await add(harness, "Docs", "https://docs.example.com")
        try await add(harness, "Wiki", "https://wiki.example.com")
        let search = try harness.command("search")
        #expect(search.fallback?.title("wik") == "Search Bookmarks for \"wik\"")
        try await harness.runFallback("search", text: "wik")
        #expect(harness.rows.map(\.title) == ["Wiki"])
    }

    @Test func rememberedRowsKeepTheirActionsAfterARelaunch() async throws {
        let fakes = FakeServices()
        let first = await activated(fakes)
        try await add(first, "Docs", "https://docs.example.com")
        let snapshot = try JSONEncoder().encode(try await first.catalogRows()[0])

        let relaunched = await activated(fakes)
        let row = try JSONDecoder().decode(Row.self, from: snapshot)
        #expect(relaunched.rootActions(for: row).map(\.id) == ["open", "copy", "paste", "pin", "delete"])
        try await relaunched.performRoot("open", on: row)
        #expect(fakes.workspace.opened == [URL(string: "https://docs.example.com")])
    }

    @Test func savesASelectedURLFromAnyApp() async throws {
        let harness = await activated()
        let selection = Selection.url(try #require(URL(string: "https://news.example.com")))
        #expect(harness.universalActions(for: .text("plain words")).isEmpty)
        try await harness.performUniversal("Save as Bookmark", on: selection)
        #expect(harness.feature.bookmarks.map(\.link) == ["https://news.example.com"])
        #expect(harness.huds == ["Saved Bookmark"])
        let row = try #require(try await harness.catalogRows().first)
        #expect(harness.universalActions(for: row).map(\.id) == ["save-bookmark"], "a row offers link actions too")
    }

    @Test func pinningReloadsThroughTheChangeSignal() async throws {
        let harness = await activated()
        try await add(harness, "Docs", "https://docs.example.com")
        try await harness.run("search")
        try await harness.perform("pin")
        #expect(harness.sections.map(\.title) == ["Pinned"])
    }

    @Test func declarationChangesAreSignalled() async throws {
        let harness = await activated()
        let changes = try #require(harness.feature.declarationChanges).stream()
        var iterator = changes.makeAsyncIterator()
        try await add(harness, "Search", "https://example.com/?q={argument}")
        await iterator.next()
        #expect(harness.feature.commands.count == 3)
    }
}
