import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct GridLayoutTests {
    let metrics = Theme.standard.grid
    let list = Theme.standard.list

    func cells(_ count: Int, from id: UInt64 = 1) -> [GridCell] {
        (0..<count).map { GridCell(id: id + UInt64($0), content: .glyph("•"), title: "Cell \($0)") }
    }

    func layout(_ sections: [GridSection], width: Double = 760, maxHeight: Double = 500) -> GridLayout {
        GridLayout(
            content: GridContent(sections: sections, columns: .fixed(4)), metrics: metrics, list: list, width: width,
            maxHeight: maxHeight)
    }

    @Test func cellsFillRowsLeftToRightAndStayCentred() throws {
        let grid = layout([GridSection(cells: cells(6))])
        #expect(grid.columns == 4)
        let first = try #require(grid.cellFrame(0))
        let fourth = try #require(grid.cellFrame(3))
        let fifth = try #require(grid.cellFrame(4))
        #expect(first.minY == fourth.minY)
        #expect(fifth.minX == first.minX)
        #expect(fifth.minY > first.maxY)
        #expect(abs(Double(first.minX) - (760 - Double(fourth.maxX))) <= 1)
    }

    @Test func headersTakeRoomAndSectionsStartNewRows() throws {
        let grid = layout([GridSection(title: "A", cells: cells(5)), GridSection(title: "B", cells: cells(2, from: 9))])
        let headers = grid.headers(overlapping: 0, 10_000)
        #expect(headers.map(\.section) == [0, 1])
        let lastOfA = try #require(grid.cellFrame(4))
        let firstOfB = try #require(grid.cellFrame(5))
        #expect(Double(firstOfB.minY) >= Double(lastOfA.maxY) + list.sectionHeaderHeight)
        #expect(firstOfB.minX == grid.cellFrame(0)?.minX)
    }

    @Test func movingInTwoDimensions() {
        // Section A: 5 cells (rows of 4 and 1). Section B: 6 cells (rows of 4 and 2).
        let grid = layout([GridSection(title: "A", cells: cells(5)), GridSection(title: "B", cells: cells(6, from: 9))])
        #expect(grid.target(from: 0, moving: .left) == nil)
        #expect(grid.target(from: 3, moving: .right) == 4)
        #expect(grid.target(from: 2, moving: .down) == 4, "a short last row clamps to its last cell")
        #expect(grid.target(from: 4, moving: .down) == 5, "down from a section's last row enters the next section")
        #expect(grid.target(from: 7, moving: .up) == 4, "up into a shorter row clamps")
        #expect(grid.target(from: 9, moving: .down) == nil)
        #expect(grid.target(from: 10, moving: .down) == nil)
        #expect(grid.target(from: 6, moving: .down) == 10)
        #expect(grid.target(from: 10, moving: .right) == nil)
    }

    @Test func pointsMapToCells() throws {
        let grid = layout([GridSection(cells: cells(6))])
        let frame = try #require(grid.cellFrame(5))
        #expect(grid.cellIndex(atX: Double(frame.midX), y: Double(frame.midY)) == 5)
        #expect(grid.cellIndex(atX: Double(frame.maxX) + metrics.spacing / 2, y: Double(frame.midY)) == nil)
        let last = try #require(grid.cellFrame(4))
        #expect(grid.cellIndex(atX: Double(last.midX) + Double(last.width) * 3, y: Double(last.midY)) == nil)
    }

    @Test func theViewportShowsWholeRowsOnly() throws {
        let grid = layout([GridSection(cells: cells(400))])
        #expect(grid.viewportHeight <= 500)
        let visible = grid.cells(overlapping: 0, grid.viewportHeight)
        let lastVisible = try #require(visible.last.flatMap { grid.cellFrame($0) })
        #expect(Double(lastVisible.maxY) + metrics.verticalPadding == grid.viewportHeight)
    }

    @Test func thousandsOfCellsLayOutAsBlocks() {
        let grid = layout([GridSection(cells: cells(3000))])
        #expect(grid.cellCount == 3000)
        #expect(grid.blocks.count == 1)
        let visible = grid.cells(overlapping: 0, grid.viewportHeight)
        #expect(visible.first == 0)
        #expect(visible.count % 4 == 0)
        #expect(visible.count < 40)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GridViewTests {
    func makeGrid() -> (grid: GridView, window: NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: Theme.standard.panel.width, height: Theme.standard.panel.maxContentHeight)
        let window = NSWindow(
            contentRect: CGRect(origin: TestSupport.offscreen.origin, size: frame.size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = FlippedTestView(frame: frame)
        window.contentView = container
        let grid = GridView(frame: frame)
        container.addSubview(grid)
        grid.apply(TestSupport.lightTheme)
        window.orderFrontRegardless()
        return (grid, window)
    }

    func content(_ cells: [GridCell]) -> GridContent {
        GridContent(sections: [GridSection(cells: cells)], columns: .glyph, emphasizesMatches: true)
    }

    /// Draws what is pending and commits it.
    func render(_ grid: GridView) {
        grid.displayIfNeeded()
        CATransaction.flush()
    }

    @Test func onlyChangedCellsAreRedrawn() {
        let (grid, window) = makeGrid()
        defer { window.close() }
        let cells = SyntheticComponents.glyphCells(count: 24)
        grid.apply(content(cells))
        render(grid)
        #expect(grid.cellsDrawnInLastPass == 24)
        var changed = cells
        changed[5].title = "Changed"
        grid.apply(content(changed))
        render(grid)
        #expect(grid.cellsDrawnInLastPass == 1)
        let passes = grid.displayPasses
        grid.apply(content(changed))
        render(grid)
        #expect(grid.displayPasses == passes, "the same content must not redraw")
    }

    @Test func filteringDrawsOnlyTheVisibleCells() {
        let (grid, window) = makeGrid()
        defer { window.close() }
        let all = SyntheticComponents.glyphCells(count: 3000)
        grid.apply(content(all))
        render(grid)
        let visible = grid.cellsDrawnInLastPass
        #expect(visible > 0 && visible < 60)
        grid.apply(content(SyntheticComponents.filter(all, by: "am")))
        render(grid)
        #expect(grid.cellsDrawnInLastPass <= visible)
    }

    @Test func arrowsMoveTheSelectionAndScrollItIntoView() throws {
        let (grid, window) = makeGrid()
        defer { window.close() }
        grid.apply(content(SyntheticComponents.glyphCells(count: 200)))
        #expect(grid.moveSelection(.right) == 0, "the first move selects the first cell")
        #expect(grid.moveSelection(.right) == 1)
        #expect(grid.moveSelection(.down) == 1 + grid.columnCount)
        #expect(grid.moveSelection(.left) == grid.columnCount)
        grid.select(199, animated: false)
        let rect = try #require(grid.cellRect(199))
        #expect(rect.minY >= 0)
        #expect(rect.maxY <= grid.preferredContentHeight(limit: 10_000))
        #expect(grid.moveSelection(.down) == nil)
    }

    @Test func theLensWrapsTheSelectedTileWithTheGridRadius() throws {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let grid = GridView()
        surface.setContent(grid, animated: false)
        grid.apply(content(SyntheticComponents.glyphCells(count: 16)))
        grid.select(9, animated: false)
        #expect(!surface.lens.isHidden)
        #expect(Double(surface.lens.cornerRadius ?? 0) == Theme.standard.grid.lensCornerRadius)
        let outset = CGFloat(Theme.standard.grid.lensOutset)
        let cell = try #require(grid.cellRect(9))
        let tile = CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: CGFloat(grid.layoutModel.tileHeight))
        // The lens wraps the tile; the title stays on the panel glass.
        let expected = grid.convert(tile.insetBy(dx: -outset, dy: -outset), to: surface.lens.view.superview)
        #expect(surface.lens.view.frame == expected)
        surface.setContent(ResultListView(), animated: false)
        #expect(surface.lens.cornerRadius == nil, "the list gets the theme radius back")
    }

    @Test func aLateImageRedrawsOnlyItsCell() {
        let (grid, window) = makeGrid()
        defer { window.close() }
        let cells = (0..<10).map { GridCell(id: UInt64($0 + 1), content: .image(nil), title: "Picture \($0)") }
        grid.apply(GridContent(sections: [GridSection(cells: cells)], columns: .image))
        render(grid)
        grid.setImage(TestSupport.image(), forCell: 4)
        render(grid)
        #expect(grid.cellsDrawnInLastPass == 1)
        if case .image(let image) = grid.cell(at: 3)?.content {
            #expect(image != nil)
        } else {
            Issue.record("not an image")
        }
    }

    @Test func aClickSelectsAndADoubleClickActivates() throws {
        let (grid, window) = makeGrid()
        defer { window.close() }
        grid.apply(content(SyntheticComponents.glyphCells(count: 12)))
        var selected: [Int] = []
        var activated: [Int] = []
        grid.onSelect = { selected.append($0) }
        grid.onActivate = { activated.append($0) }
        let rect = try #require(grid.cellRect(6))
        let point = grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for clicks in 1...2 {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
            grid.mouseDown(with: event)
        }
        #expect(selected == [6])
        #expect(activated == [6])
    }
}
