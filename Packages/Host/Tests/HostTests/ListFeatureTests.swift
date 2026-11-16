import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Lists: paging on scroll, dropdowns, notices, load reasons, live subtitles, Quick Look and share.
@Suite("Panel: list features", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ListFeatureTests {
    private func openList(
        _ fixture: PanelFixture, _ source: GatedSource, filter: FilterDropdown? = nil, title: String = "Notes"
    ) async -> ListPageController? {
        let page = fixture.open(.list(ListPage(source, title: title, filter: filter)))
        guard let list = page as? ListPageController, await waitUntil({ list.loadCount >= 1 }) else { return nil }
        return list
    }

    private static let types = FilterDropdown(
        title: "Type",
        options: [
            FilterOption(id: "all", title: "All Types"), FilterOption(id: "a", title: "A"),
            FilterOption(id: "b", title: "B"),
        ])

    @Test func scrollingNearTheEndLoadsTheNextPage() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: (1...60).map { "Note \($0)" })
        source.filtering = .custom(debounce: .zero)
        source.pageSize = 20
        let page = try #require(await openList(fixture, source))
        #expect(page.list.content.rowCount == 20)
        page.contentDidScroll()
        #expect(source.requests.count == 1, "the end is not in view yet")
        // The list reports the scroll itself; nothing calls the page.
        page.list.scroll(to: 10_000)
        #expect(await waitUntil { page.list.content.rowCount == 40 })
        #expect(source.requests.map(\.reason) == [.open, .nextPage])
        #expect(source.requests.last?.page == ListPageToken("20"))
    }

    @Test func aReplacedDropdownFallsBackToItsDefault() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha", "beta"])
        let page = try #require(await openList(fixture, source, filter: Self.types))
        fixture.panel.queryField(fixture.field, didChooseFilter: MenuOption(id: "b", title: "B"))
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(fixture.titles(page.list) == ["beta"])
        source.replacementFilter = FilterDropdown(
            title: "Type", options: [FilterOption(id: "all", title: "All Types"), FilterOption(id: "a", title: "A")])
        page.reload()
        #expect(await waitUntil { page.loadCount == 3 })
        #expect(page.filterID == "all", "the chosen option is gone, so the default applies")
        #expect(source.requests.map(\.reason) == [.open, .filter, .reload, .filter])
        #expect(source.requests.last?.filter == "all")
        #expect(fixture.field.filter?.options.map(\.id) == ["all", "a"])
        #expect(fixture.titles(page.list) == ["alpha", "beta"])
    }

    @Test func aRememberedDropdownOpensWithTheLastChoice() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha", "beta"])
        _ = try #require(await openList(fixture, source, filter: Self.types))
        fixture.panel.queryField(fixture.field, didChooseFilter: MenuOption(id: "a", title: "A"))
        fixture.press(.cancel([]))
        let again = try #require(await openList(fixture, source, filter: Self.types))
        #expect(again.filterID == "a")
        #expect(source.requests.last?.filter == "a")
        #expect(fixture.field.filter?.selectedID == "a")
    }

    @Test func aNoticeDrawsAsABannerWithItsButton() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let granted = Box(0)
        let source = GatedSource(titles: ["alpha"])
        source.notice = Notice(
            icon: .symbol("lock"), title: "Search is limited", message: "Grant Full Disk Access",
            action: Action("Grant Access", id: "grant") { _ in
                granted.value += 1
                return .keepOpen
            })
        let page = try #require(await openList(fixture, source))
        #expect(page.contentView.banner != nil)
        #expect(page.contentView.bannerHeight > 0)
        #expect(page.list.frame.minY == page.contentView.bannerHeight, "the rows sit under the banner")
        fixture.command("k")
        #expect(fixture.panel.actionEntries.map(\.title) == ["Use", "Inspect", "Grant Access"])
        #expect(fixture.panel.actionTarget?.secondary?.title == "Inspect", "the notice never takes Command-Return")
        fixture.panel.surface.dismissOverlay()
        source.notice = nil
        page.reload()
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(page.contentView.banner == nil)
    }

    @Test func typingWhileTheFirstLoadRunsShowsNoEmptyState() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = GatedSource(titles: ["alpha", "beta"])
        source.gated = true
        let page = try #require(fixture.open(.list(ListPage(source, title: "Notes"))) as? ListPageController)
        #expect(await waitUntil { source.gate.waiting == 1 })
        fixture.type("bet")
        #expect(!(page.contentView.child is EmptyStateView), "no empty state before the rows arrive")
        source.gate.open()
        #expect(await waitUntil { page.loadCount == 1 })
        #expect(fixture.titles(page.list) == ["beta"], "the rows that arrive are filtered by what was typed")
    }

    @Test func aLiveSubtitleRefreshRedrawsAndKeepsTheSelection() async throws {
        _ = NSApplication.shared
        let runtime = RuntimeFixture()
        await runtime.start()
        let root = SubtitleRoot()
        let surface = LauncherSurface(visibleFrame: PanelFixture.offscreen)
        let panel = PanelController(
            runtime: runtime.runtime, rootSource: root, icons: FakeIconProvider(), surface: surface,
            hud: RecordingHUD())
        panel.summoner.takesKeyStatus = false
        panel.summoner.followsPointerScreen = false
        defer { surface.panel.close() }
        panel.prewarm()
        panel.summon()
        _ = panel.queryField(surface.queryField, perform: .moveDown)
        #expect(panel.rootPage.list.selectedRow == 1)
        root.refreshSubtitle("12:30")
        #expect(await waitUntil { panel.rootPage.list.content.sections.first?.rows.last?.subtitle == "12:30" })
        #expect(panel.rootPage.list.selectedRow == 1)
    }

    @Test func rootHighlightsFillForRowsScrolledIntoView() async throws {
        let rows = (1...30).map { Row(id: ItemID("demo", String($0)), title: "Sample \($0)", icon: .symbol("doc")) }
        let fixture = await PanelFixture.make(rows: rows)
        defer { fixture.close() }
        fixture.type("sam")
        let list = fixture.panel.rootPage.list
        #expect(list.content.sections[0].rows[20].titleHighlights.isEmpty, "Root fills the first twelve")
        // The list reports the scroll itself; nothing calls the page.
        list.scroll(to: 10_000)
        #expect(list.content.sections[0].rows[29].titleHighlights == [HighlightRange(location: 0, length: 3)])
    }

    @Test func clickingTheBannerRunsTheNoticeAction() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let pressed = Box(0)
        let source = GatedSource(titles: ["alpha"])
        source.notice = Notice(
            title: "Search is limited",
            action: Action("Grant Access", id: "grant") { _ in
                pressed.value += 1
                return .keepOpen
            })
        let page = try #require(await openList(fixture, source))
        let banner = try #require(page.contentView.banner)
        #expect(banner.accessibilityPerformPress())
        #expect(await waitUntil { pressed.value == 1 })
    }

    // MARK: Quick Look and share

    @Test func commandYPreviewsInsideThePanel() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        var previewed: [URL] = []
        fixture.panel.makePreviewView = { url in
            previewed.append(url)
            return NSView()
        }
        let first = URL(fileURLWithPath: "/tmp/example/first.txt")
        let second = URL(fileURLWithPath: "/tmp/example/second.txt")
        fixture.panel.quickLook([first, second])
        let page = try #require(fixture.panel.top as? QuickLookPageController)
        #expect(page.title == "first.txt  1 of 2")
        #expect(previewed == [first])
        #expect(fixture.press(.moveRight))
        #expect(page.url == second)
        #expect(fixture.command("y"))
        #expect(fixture.panel.top === fixture.panel.rootPage)
    }

    @Test func aRowsQuickLookURLOpensOnCommandY() async throws {
        let url = URL(fileURLWithPath: "/tmp/example/notes.txt")
        var row = SampleRows.note
        row.quickLookURL = url
        let fixture = await PanelFixture.make(rows: [row])
        defer { fixture.close() }
        fixture.panel.makePreviewView = { _ in NSView() }
        fixture.type("Notes")
        #expect(fixture.command("y"))
        #expect((fixture.panel.top as? QuickLookPageController)?.url == url)
    }

    @Test func shareListsTheSheetsServicesInTheCard() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let sheet = FakeShareSheet()
        fixture.panel.shareSheet = sheet
        fixture.panel.share([.text("hello")])
        #expect(fixture.panel.surface.overlay === fixture.panel.actionCard)
        #expect(fixture.panel.actionEntries.map(\.title) == ["Mail", "Notes"])
        fixture.panel.actionCard.selectItem(at: 1)
        fixture.panel.actionCard.onActivate?(try #require(fixture.panel.actionCard.selectedItem))
        #expect(sheet.shared.map(\.option) == ["notes"])
        #expect(sheet.shared.first?.items == [.text("hello")])
    }

    @Test func shareWithoutASheetSaysItIsNotAvailable() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        #expect(fixture.panel.shareSheet == nil, "nothing shares outside the live app")
        fixture.panel.share([.text("hello")])
        #expect(fixture.panel.surface.actionBar.toast?.text == "Sharing Is Not Available Here")
    }
}
