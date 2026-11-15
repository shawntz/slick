import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct ResultListViewTests {
    let catalog = SyntheticCatalog()

    @Test func onlyChangedRowsAreRedrawn() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.rotatingContent(step: 0))
        list.displayIfNeeded()
        #expect(list.rowsDrawnInLastPass == 9)

        var content = list.content
        content.sections[0].rows[3].title = "Changed title"
        list.apply(content)
        list.displayIfNeeded()
        #expect(list.rowsDrawnInLastPass == 1)

        let passes = list.displayPasses
        list.apply(content)
        list.displayIfNeeded()
        #expect(list.displayPasses == passes, "applying the same content must not redraw")
    }

    @Test func aLateIconRedrawsOnlyItsRow() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["One", "Two", "Three", "Four"]))]))
        list.displayIfNeeded()
        list.setIcon(TestSupport.image(), forRow: 3)
        list.displayIfNeeded()
        #expect(list.rowsDrawnInLastPass == 1)
        #expect(list.row(at: 2)?.icon != nil)
        #expect(list.row(at: 1)?.icon == nil)
    }

    @Test func everyRowChangingRedrawsEveryRow() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.rotatingContent(step: 0))
        list.displayIfNeeded()
        list.apply(catalog.rotatingContent(step: 1))
        list.displayIfNeeded()
        #expect(list.rowsDrawnInLastPass == 9)
    }

    @Test func selectionScrollsTheRowIntoView() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.content(for: "e"))
        #expect(list.content.rowCount > 12)
        list.select(12, animated: false)
        let rect = list.rowRect(12)!
        #expect(rect.minY >= 0)
        #expect(rect.maxY <= list.preferredContentHeight(limit: 10_000))
        list.select(0, animated: false)
        #expect(list.scrollOffset == 0)
    }

    @Test func movingTheSelectionStopsAtTheEnds() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["A", "B", "C"]))]))
        #expect(list.moveSelection(by: 1) == 0)
        #expect(list.moveSelection(by: 5) == 2)
        #expect(list.moveSelection(by: -9) == 0)
    }

    @Test func sectionJumpsMoveTheSelection() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.rootContent())
        list.select(1, animated: false)
        #expect(list.moveSelectionToSection(forward: true) == 5)
        #expect(list.moveSelectionToSection(forward: false) == 0)
    }

    @Test func scrollingIsClampedToTheContent() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.content(for: "e"))
        list.scroll(to: 100_000)
        let viewport = list.preferredContentHeight(limit: 10_000)
        let last = list.rowRect(list.content.rowCount - 1)!
        #expect(last.maxY <= viewport)
        list.scroll(to: -50)
        #expect(list.scrollOffset == 0)
    }

    @Test func theWheelScrolls() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(catalog.content(for: "e"))
        let wheel = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0))
        list.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(list.scrollOffset == 60)
    }

    @Test func aClickSelectsAndADoubleClickActivates() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["A", "B", "C"]))]))
        var selected: [Int] = []
        var activated: [Int] = []
        list.onSelect = { selected.append($0) }
        list.onActivate = { activated.append($0) }
        let rowCenter = list.rowRect(1)!
        let point = list.convert(NSPoint(x: rowCenter.midX, y: rowCenter.midY), to: nil)
        for clicks in 1...2 {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
                ))
            list.mouseDown(with: event)
        }
        #expect(selected == [1])
        #expect(activated == [1])
        #expect(list.selectedRow == 1)
    }

    @Test func theLensFollowsTheSelectedRow() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let list = ResultListView()
        surface.setContent(list, animated: false)
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["A", "B", "C"]))]))
        #expect(surface.lens.isHidden)
        list.select(2, animated: false)
        #expect(!surface.lens.isHidden)
        let expected = list.convert(
            list.rowRect(2)!.insetBy(dx: Theme.standard.lens.horizontalInset, dy: 0), to: surface.lens.view.superview)
        #expect(surface.lens.view.frame == expected)
        list.apply(ListContent.empty)
        #expect(surface.lens.isHidden)
    }

    @Test func textDoesNotShiftWhenMatchesChange() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        let plain = ListRow(id: 1, title: "Aurora Notes", subtitle: "Application")
        var matched = plain
        matched.titleHighlights = [HighlightRange(location: 0, length: 3)]
        list.apply(ListContent(sections: [ListSection(rows: [plain])], emphasizesMatches: true))
        let before = list.textFrames(row: 0)
        list.apply(ListContent(sections: [ListSection(rows: [matched])], emphasizesMatches: true))
        let after = list.textFrames(row: 0)
        #expect(before?.title == after?.title)
        #expect(before?.subtitle == after?.subtitle)
    }

    @Test func theSubtitleGivesWayBeforeTheTitle() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        let long = String(repeating: "Very long title ", count: 9)
        list.apply(ListContent(sections: [ListSection(rows: [ListRow(id: 1, title: long, subtitle: "Application")])]))
        let frames = list.textFrames(row: 0)
        #expect(frames?.subtitle == nil)
        #expect((frames?.title.width ?? 0) > 300)
    }
}
