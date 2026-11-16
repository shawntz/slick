import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Lists that commands push: host and custom filtering, reloads, selection and empty states.
@Suite("Panel: list pages", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ListPageTests {
    private func openShelf(_ fixture: PanelFixture) async -> ListPageController? {
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-shelf"), launch: .root)
        guard await waitUntil({ fixture.topList?.loadCount == 1 }) else { return nil }
        return fixture.topList
    }

    /// A page without a title of its own shows the command's title, so the breadcrumb and
    /// scenarios can name it.
    @Test func anUntitledPageTakesItsCommandsTitle() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-untitled"), launch: .root)
        #expect(await waitUntil { fixture.topList?.loadCount == 1 })
        #expect(fixture.panel.top.title == "Browse Shelf")
        #expect(fixture.field.leading == QueryLeading(glyph: .back, breadcrumb: "Browse Shelf"))
    }

    @Test func aPushedListLoadsOnceAndFiltersInTheHost() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openShelf(fixture))
        #expect(fixture.root.calls.last == .end, "root search left the screen")
        #expect(fixture.field.leading == QueryLeading(glyph: .back, breadcrumb: "Shelf"))
        #expect(page.list.content.sections.map(\.title) == ["Recent", "All"])
        #expect(page.list.content.sections.map(\.count) == [nil, 4], "the header draws the count")
        #expect(fixture.titles(page.list) == ["Apple", "Apple", "Apple Pie", "Banana", "Cherry"])
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Take")

        fixture.type("app")
        #expect(page.list.content.sections.map(\.title) == ["All"], "Recent hides while searching")
        #expect(page.list.content.sections.map(\.count) == [2])
        #expect(fixture.titles(page.list) == ["Apple Pie", "Apple"], "the hint wins inside the prefix tier")
        #expect(page.list.content.sections[0].rows[0].titleHighlights == [HighlightRange(location: 0, length: 3)])
        fixture.type("apple")
        #expect(fixture.titles(page.list) == ["Apple", "Apple Pie"], "a stronger tier wins over any hint")
        #expect(fixture.runtime.fakes.fuzzyIndex.builtIndexSizes == [5], "indexed once, not per keystroke")
        #expect(fixture.runtime.workbench.shelf.requests.map(\.reason) == [.open])
    }

    /// Inside a tier a title match beats a keyword match, whatever the rank hint says; the hint
    /// orders title matches among themselves. As Emoji asks: "heart" finds Heart Suit before the
    /// often used Red Heart, which only its keyword reaches.
    @Test(arguments: [false, true])
    func aTitleMatchBeatsAKeywordMatchAheadOfTheRankHint(grid: Bool) async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let rows = [
            Row(id: ItemID("glyph", "red"), title: "Red Heart", keywords: ["heart", "love"], rankHint: 10),
            Row(id: ItemID("glyph", "suit"), title: "Heart Suit", rankHint: 0),
            Row(id: ItemID("glyph", "beat"), title: "Heartbeat", rankHint: 5),
            Row(id: ItemID("glyph", "letter"), title: "Love Letter", rankHint: 1),
            Row(id: ItemID("glyph", "plain"), title: "Heart", rankHint: 0),
        ]
        let section = [ListSection("Symbols", id: "symbols", rows: rows)]
        let page =
            grid
            ? fixture.open(.grid(GridPage(StaticRows(section), title: "Symbols", showsTitles: true)))
            : fixture.open(.list(ListPage(StaticRows(section), title: "Symbols")))
        #expect(await waitUntil { !page.isBusy && fixture.panel.shownTitles.count == 5 })
        fixture.type("heart")
        #expect(
            fixture.panel.shownTitles == ["Heart", "Red Heart", "Heartbeat", "Heart Suit"],
            "the exact title before the exact keyword with a higher hint, then the prefixes by hint")
        fixture.type("love")
        #expect(
            fixture.panel.shownTitles == ["Red Heart", "Love Letter"],
            "a keyword equal to the query before a title that only starts with it")
    }

    @Test func theSelectionIsKeyedBySectionAndRow() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openShelf(fixture))
        fixture.press(.moveDown)
        #expect(page.selectedRow?.title == "Apple")
        #expect(page.list.selectedRow == 1, "the second Apple, in All")
        fixture.runtime.workbench.shelf.items.insert("Apricot", at: 2)
        fixture.runtime.workbench.shelf.changes?.send()
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(page.list.selectedRow == 1, "still the Apple in All")
        #expect(page.loadReasons == [.open, .reload])
    }

    @Test func settingsAndActionReloadsLoadAgain() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openShelf(fixture))
        fixture.runtime.fakes.settings.set(.string("date"), for: "workbench.sort")
        #expect(await waitUntil { page.loadCount == 2 })
        await fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("reloading"), launch: .page).value
        #expect(await waitUntil { page.loadCount == 3 })
        #expect(page.loadReasons == [.open, .reload, .reload])
    }

    @Test func refreshAfterLoadsAgainWhileTheQueryStands() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.workbench.shelf.refreshAfter = .seconds(5)
        let page = try #require(await openShelf(fixture))
        await fixture.runtime.fakes.clock.waitForSleepers(1)
        fixture.runtime.fakes.clock.advance(by: .seconds(5))
        #expect(await waitUntil { page.loadReasons.contains(.refresh) })
    }

    @Test func anEmptyListShowsItsEmptyState() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.workbench.shelf.items = []
        let page = try #require(await openShelf(fixture))
        #expect(page.contentView.child is EmptyStateView)
        #expect((page.contentView.child as? EmptyStateView)?.content.title == "Nothing on the Shelf")
        #expect(page.target == nil)
    }

    @Test func customFilteringLoadsPerQueryAndInPages() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("open-ledger"), launch: .root)
        #expect(await waitUntil { fixture.topList?.loadCount == 1 })
        let page = try #require(fixture.topList)
        #expect(fixture.titles(page.list) == ["Entry 1", "Entry 2"])
        fixture.press(.moveDown)
        #expect(await waitUntil { fixture.titles(page.list).count == 4 }, "the next page appends")
        fixture.type("Entry 7")
        #expect(await waitUntil { fixture.titles(page.list) == ["Entry 7"] })
        let ledger = fixture.runtime.workbench.ledger
        #expect(ledger.requests.map(\.reason) == [.open, .nextPage, .query])
        #expect(ledger.requests.last?.query == "Entry 7")
        #expect(page.list.content.sections[0].rows[0].titleHighlights == [HighlightRange(location: 0, length: 1)])
    }

    @Test func backFromAListReturnsToRootAndBeginsAgain() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        _ = try #require(await openShelf(fixture))
        #expect(fixture.press(.deleteOnEmpty))
        #expect(fixture.panel.top === fixture.panel.rootPage)
        #expect(fixture.root.calls.last == .begin)
        #expect(fixture.field.leading == .root)
    }

    @Test func formsGridsAndDetailsOpenTheirPages() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("form"), launch: .root)
        #expect(await waitUntil { fixture.panel.top is FormPageController })
        #expect(fixture.panel.top.title == "New Item")
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Save")
        _ = fixture.open(.grid(GridPage(Tiles(count: 3), title: "Tiles")))
        #expect(fixture.panel.top is GridPageController)
        _ = fixture.open(.detail(DetailPage(title: "About", detail: .markdown("Hello"))))
        #expect(fixture.panel.top is DetailPageController)
    }
}

/// A host-filtered source over fixed sections.
@MainActor final class StaticRows: ListSource {
    let sections: [Kit.ListSection]

    init(_ sections: [Kit.ListSection]) {
        self.sections = sections
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: sections)
    }

    func actions(for row: Row) -> [Action] { [] }
}
