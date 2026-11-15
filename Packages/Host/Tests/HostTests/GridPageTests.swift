import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Grid pages: the list's loading and filtering drawn as cells, with two-dimensional keys.
@Suite("Panel: grid pages", .serialized, .timeLimit(.minutes(1)))
@MainActor struct GridPageTests {
    private func openGrid(_ fixture: PanelFixture, _ source: Tiles, columns: Int = 5) async -> GridPageController? {
        let page = fixture.open(.grid(GridPage(source, title: "Tiles", columns: columns, showsTitles: true)))
        guard let grid = page as? GridPageController, await waitUntil({ grid.loadCount == 1 }) else { return nil }
        return grid
    }

    @Test func rowsBecomeCellsByTheirIcon() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openGrid(fixture, Tiles(count: 12)))
        let cells = page.grid.content.sections.flatMap(\.cells)
        #expect(cells.count == 12)
        if case .image(let image) = cells[0].content {
            #expect(image != nil, "a glyph draws as an image from the icon provider")
        } else {
            Issue.record("the glyph is not an image")
        }
        #expect(fixture.icons.lookups.contains(.glyph("★")))
        #expect(cells[1].content == .color(ThemeColor(red: 1, green: 0, blue: 0, alpha: 1)))
        if case .image(let image) = cells[2].content { #expect(image != nil) } else { Issue.record("not an image") }
        #expect(page.grid.content.columns == .fixed(5))
        #expect(page.grid.selectedIndex == 0)
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Use")
        #expect(fixture.field.leading == QueryLeading(glyph: .back, breadcrumb: "Tiles"))
    }

    @Test func arrowsMoveInTwoDimensions() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openGrid(fixture, Tiles(count: 12)))
        page.grid.frame = CGRect(x: 0, y: 0, width: 760, height: 468)
        #expect(fixture.press(.moveRight))
        #expect(page.grid.selectedIndex == 1)
        #expect(fixture.press(.moveDown))
        #expect(page.grid.selectedIndex == 6)
        #expect(fixture.press(.moveLeft))
        #expect(page.grid.selectedIndex == 5)
        #expect(fixture.press(.moveUp))
        #expect(page.grid.selectedIndex == 0)
        #expect(page.selectedRow?.title == "Tile 1")
    }

    @Test func typingFiltersTheMappedCellsWithoutMappingAgain() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Tiles(count: 30)
        let page = try #require(await openGrid(fixture, source))
        fixture.type("Tile 2")
        let titles = page.grid.content.sections.flatMap(\.cells).map(\.title)
        #expect(titles.first == "Tile 2")
        #expect(titles.count < 30 && titles.allSatisfy { $0.contains("2") })
        #expect(page.grid.content.sections[0].cells[0].titleHighlights.isEmpty == false)
        fixture.type("")
        #expect(page.grid.content.cellCount == 30)
        #expect(page.cellBuilds == 1, "cells are mapped once per load")
        #expect(source.requests.map(\.reason) == [.open])
    }

    @Test func theSelectionStaysOnItsCellWhileFiltering() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openGrid(fixture, Tiles(count: 30)))
        page.grid.frame = CGRect(x: 0, y: 0, width: 760, height: 468)
        for _ in 0..<4 { fixture.press(.moveRight) }
        #expect(page.selectedRow?.title == "Tile 5")
        fixture.type("Tile")
        #expect(page.selectedRow?.title == "Tile 5")
    }

    @Test func commandPlusAndMinusChangeTheColumns() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = try #require(await openGrid(fixture, Tiles(count: 12)))
        #expect(fixture.command("="))
        #expect(page.columns == 4)
        #expect(fixture.command("-"))
        #expect(fixture.command("-"))
        #expect(page.columns == 6)
        #expect(page.grid.content.columns == .fixed(6))
        #expect(page.cellBuilds == 4, "each new size looks the icons up again")
    }

    @Test func lateIconsFillTheirCells() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.icons.holdBack(.symbol("photo.3"))
        let page = try #require(await openGrid(fixture, Tiles(count: 5)))
        #expect(page.grid.content.sections[0].cells[2].content == .image(nil))
        fixture.icons.deliverHeldIcons()
        #expect(
            await waitUntil {
                if case .image(let image) = page.grid.content.sections[0].cells[2].content { return image != nil }
                return false
            })
    }

    @Test func aGlyphDrawsAsTextUntilItsImageIsReady() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.icons.holdBack(.glyph("★"))
        let page = try #require(await openGrid(fixture, Tiles(count: 5)))
        #expect(page.grid.content.sections[0].cells[0].content == .glyph("★"))
        fixture.icons.deliverHeldIcons()
        #expect(
            await waitUntil {
                if case .image(let image) = page.grid.content.sections[0].cells[0].content { return image != nil }
                return false
            })
    }

    /// Emoji's grid hides titles: the action bar names the selected cell instead of the page.
    @Test func aGridWithoutTitlesNamesTheSelectedCellInTheActionBar() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let page = fixture.open(.grid(GridPage(Tiles(count: 12), title: "Tiles", columns: 5, showsTitles: false)))
        let grid = try #require(page as? GridPageController)
        #expect(await waitUntil { grid.loadCount == 1 })
        #expect(fixture.panel.surface.actionBar.content.viewTitle == "Tile 1")
        fixture.press(.moveRight)
        #expect(fixture.panel.surface.actionBar.content.viewTitle == "Tile 2")
        let titled = try #require(await openGrid(fixture, Tiles(count: 3)))
        #expect(titled.selectionTitle == nil)
        #expect(fixture.panel.surface.actionBar.content.viewTitle == "Tiles")
    }

    /// Command-Period reaches a cell's action, as Emoji's Pin uses it.
    @Test func aCellActionsShortcutRunsIt() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Tiles(count: 6)
        let page = try #require(await openGrid(fixture, source))
        page.grid.frame = CGRect(x: 0, y: 0, width: 760, height: 468)
        fixture.press(.moveRight)
        #expect(fixture.command("."))
        #expect(await waitUntil { source.pinned == [ItemID("tile", "2")] })
        #expect(fixture.panel.surface.overlay == nil, "the shortcut runs without the action panel")
        #expect(fixture.panel.top === page)
    }

    @Test func customFilteringPagesAsTheSelectionNearsTheEnd() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Tiles(count: 40)
        source.filtering = .custom(debounce: .zero)
        source.pageSize = 10
        let page = try #require(await openGrid(fixture, source))
        page.grid.frame = CGRect(x: 0, y: 0, width: 760, height: 468)
        #expect(page.grid.content.cellCount == 10)
        fixture.press(.moveDown)
        #expect(await waitUntil { page.grid.content.cellCount == 20 })
        #expect(source.requests.map(\.reason) == [.open, .nextPage])
        fixture.type("Tile 3")
        #expect(await waitUntil { page.loadCount == 2 })
        #expect(source.requests.last?.reason == .query)
    }

    @Test func anEmptyGridShowsItsEmptyStateAfterLoading() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let source = Tiles(count: 0)
        let page = fixture.open(.grid(GridPage(source, emptyState: EmptyState(title: "No Images"))))
        let grid = try #require(page as? GridPageController)
        #expect(await waitUntil { grid.loadCount == 1 })
        #expect((grid.contentView.child as? EmptyStateView)?.content.title == "No Images")
    }
}
