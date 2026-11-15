import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct ListLayoutTests {
    let metrics = Theme.standard.list

    func content(_ counts: [Int], titled: Bool = true, style: RowStyle = .oneLine) -> ListContent {
        var id: UInt64 = 0
        let sections = counts.enumerated().map { index, count in
            ListSection(
                title: titled ? "Section \(index)" : nil,
                rows: (0..<count).map { _ in
                    id += 1
                    return ListRow(id: id, title: "Row \(id)")
                })
        }
        return ListContent(sections: sections, rowStyle: style)
    }

    @Test func headersAndRowsStackTopDown() {
        let layout = ListLayout(content: content([2, 1]), metrics: metrics, maxHeight: 1000)
        let kinds = layout.lines.map(\.kind)
        #expect(
            kinds == [
                .header(section: 0), .row(section: 0, row: 0, index: 0), .row(section: 0, row: 1, index: 1),
                .header(section: 1), .row(section: 1, row: 0, index: 2),
            ])
        #expect(layout.lines[0].y == metrics.verticalPadding)
        #expect(layout.lines[1].y == metrics.verticalPadding + metrics.sectionHeaderHeight)
        let expected = metrics.verticalPadding * 2 + metrics.sectionHeaderHeight * 2 + metrics.rowHeight * 3
        #expect(layout.contentHeight == expected)
        #expect(layout.viewportHeight == expected)
    }

    @Test func emptySectionsTakeNoSpace() {
        let layout = ListLayout(content: content([0, 2, 0]), metrics: metrics, maxHeight: 1000)
        #expect(layout.lines.count == 3)
        #expect(layout.sectionStarts == [0])
        #expect(ListLayout(content: content([0]), metrics: metrics, maxHeight: 1000).viewportHeight == 0)
    }

    @Test func viewportShowsNineRowsThenScrolls() {
        let layout = ListLayout(content: content([30], titled: false), metrics: metrics, maxHeight: 1000)
        #expect(layout.viewportHeight == metrics.verticalPadding * 2 + metrics.rowHeight * 9)
        #expect(layout.maxScrollOffset == metrics.rowHeight * 21)
        let capped = ListLayout(content: content([30], titled: false), metrics: metrics, maxHeight: 200)
        #expect(capped.viewportHeight == 200)
    }

    @Test func twoLineRowsAreTaller() {
        let layout = ListLayout(
            content: content([3], titled: false, style: .twoLine), metrics: metrics, maxHeight: 1000)
        #expect(layout.rowLine(1)?.height == metrics.twoLineRowHeight)
    }

    @Test func rowLookupByOffset() {
        let layout = ListLayout(content: content([2, 2]), metrics: metrics, maxHeight: 1000)
        let firstRow = metrics.verticalPadding + metrics.sectionHeaderHeight
        #expect(layout.rowIndex(atY: firstRow + 1) == 0)
        #expect(layout.rowIndex(atY: firstRow + metrics.rowHeight + 1) == 1)
        #expect(layout.rowIndex(atY: metrics.verticalPadding + 1) == nil)
        #expect(layout.rowIndex(atY: 0) == nil)
        #expect(layout.rowIndex(atY: 10_000) == nil)
    }

    @Test func sectionJumps() {
        let layout = ListLayout(content: content([3, 2, 4]), metrics: metrics, maxHeight: 1000)
        #expect(layout.nextSectionStart(after: 0) == 3)
        #expect(layout.nextSectionStart(after: 4) == 5)
        #expect(layout.nextSectionStart(after: 6) == nil)
        #expect(layout.previousSectionStart(before: 7) == 5)
        #expect(layout.previousSectionStart(before: 5) == 3)
        #expect(layout.previousSectionStart(before: 0) == nil)
    }

    @Test func visibleLineRange() {
        let layout = ListLayout(content: content([20], titled: false), metrics: metrics, maxHeight: 1000)
        let range = layout.lineIndices(
            overlapping: metrics.verticalPadding + metrics.rowHeight * 2.5,
            metrics.verticalPadding + metrics.rowHeight * 4)
        #expect(range == 2..<4)
    }
}
