import AppKit
import CoreText
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// What Host asked for before the first launch: a subtitle colour per row, a public way to clear
/// the action card's filter, and a count in section headers.
@Suite(.timeLimit(.minutes(1)))
struct FirstLaunchRequestTests {
    // MARK: Subtitle colour

    @Test func aRowsSubtitleDrawsInItsOwnColourMadeLegible() throws {
        let theme = TestSupport.lightTheme
        // Pale yellow is far too faint over light glass.
        let pale = CGColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1)
        let colored = typeset(ListRow(id: 1, title: "Build", subtitle: "Passing", subtitleColor: pale), theme: theme)
        let subtitle = try #require(colored.subtitle)
        let drawn = try #require(Self.colors(of: subtitle.line).first)
        let expected = theme.legible(pale, minimumRatio: 3)
        #expect(drawn == expected)
        #expect(Self.ratio(drawn, theme: theme) >= 3 - 0.01)
        #expect(Self.hue(drawn) > 0.1 && Self.hue(drawn) < 0.2, "the colour keeps its yellow hue")

        let plain = typeset(ListRow(id: 1, title: "Build", subtitle: "Passing"), theme: theme)
        let plainSubtitle = try #require(plain.subtitle)
        #expect(Self.colors(of: plainSubtitle.line) == [theme.subtitle])
    }

    @Test func aTruncatedSubtitleKeepsItsColourToTheEllipsis() throws {
        let theme = TestSupport.lightTheme
        let red = CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        let row = ListRow(
            id: 1, title: "Title", subtitle: String(repeating: "A long subtitle that will not fit ", count: 6),
            subtitleColor: red)
        for style in [RowStyle.oneLine, .twoLine] {
            let set = RowTypesetter.typeset(
                row, width: 420, height: 52, style: style, emphasizesMatches: false, theme: theme, scale: 2)
            let subtitle = try #require(set.subtitle)
            let colors = Self.colors(of: subtitle.line)
            #expect(colors.count >= 2, "the text and the ellipsis are separate runs")
            #expect(Set(colors).count == 1)
            #expect(colors.first == theme.legible(red, minimumRatio: 3))
        }
    }

    @Test func changingOnlyTheSubtitleColourRedrawsThatRow() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["One", "Two", "Three"]))]))
        list.displayIfNeeded()
        var content = list.content
        content.sections[0].rows[1].subtitleColor = CGColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1)
        list.apply(content)
        list.displayIfNeeded()
        #expect(list.rowsDrawnInLastPass == 1)
    }

    // MARK: Action card filter

    @Test func clearingTheFilterShowsEveryActionAgain() {
        let surface = OverlayTests().makeSurface()
        defer { surface.panel.close() }
        let card = ActionCardView(content: SyntheticComponents.actions)
        var queries: [String] = []
        card.onQueryChange = { queries.append($0) }
        surface.present(card)
        let every = card.list.rowCount
        surface.panel.queryFieldEditor.insertText("hot", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(card.list.rowCount < every)
        #expect(queries == ["hot"])

        card.clearFilter()
        #expect(card.query.isEmpty)
        #expect(card.list.rowCount == every)
        #expect(card.selectedItem == card.list.item(at: 0))
        #expect(queries == ["hot"], "a clear the host asked for is not reported back")
        #expect(surface.overlay === card, "clearing never closes the card")

        // A card the host filters only loses its text; the host applies the actions.
        let hostFiltered = ActionCardView(content: SyntheticComponents.actions)
        hostFiltered.filtersItself = false
        hostFiltered.filterField.stringValue = "hot"
        hostFiltered.clearFilter()
        #expect(hostFiltered.query.isEmpty)
    }

    // MARK: Section counts

    @Test func aSectionHeaderDrawsItsCountAfterTheTitle() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        let rows = TestSupport.rows(["One", "Two", "Three"])
        list.apply(ListContent(sections: [ListSection(title: "Today", rows: rows)]))
        let plain = try #require(list.headerTextFrames().first)
        list.apply(ListContent(sections: [ListSection(title: "Today", rows: rows, count: 3)]))
        let counted = try #require(list.headerTextFrames().first)
        #expect(counted.minX == plain.minX)
        #expect(counted.width > plain.width + 6, "the count follows the title after a gap")
        #expect(list.content.sections[0].headerText == "Today\u{2002}3")
        let header = list.accessibilityChildren()?.first as? NSAccessibilityElement
        #expect(header?.accessibilityLabel() == "Today, 3")
    }

    @Test func aCountAloneMakesAHeader() {
        let section = ListSection(rows: TestSupport.rows(["One"]), count: 1)
        let layout = ListLayout(
            content: ListContent(sections: [section]), metrics: Theme.standard.list, maxHeight: 1000)
        #expect(layout.lines.first?.kind == .header(section: 0))
        #expect(section.headerText == "1")
        let unheaded = ListLayout(
            content: ListContent(sections: [ListSection(rows: TestSupport.rows(["One"]))]),
            metrics: Theme.standard.list, maxHeight: 1000)
        #expect(unheaded.lines.first?.kind == .row(section: 0, row: 0, index: 0))
        let grid = GridSection(cells: SyntheticComponents.glyphCells(count: 3), count: 3)
        #expect(grid.hasHeader)
        #expect(grid.headerText == "3")
    }

    @Test func aNewCountRedrawsTheHeaderAndNoRow() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        let rows = TestSupport.rows(["One", "Two", "Three"])
        list.apply(ListContent(sections: [ListSection(title: "Today", rows: rows, count: 3)]))
        list.displayIfNeeded()
        let passes = list.displayPasses
        list.apply(ListContent(sections: [ListSection(title: "Today", rows: rows, count: 4)]))
        list.displayIfNeeded()
        #expect(list.displayPasses == passes + 1)
        #expect(list.rowsDrawnInLastPass == 0)
    }

    @Test func aGridHeaderTakesACountToo() throws {
        let (grid, window) = GridViewTests().makeGrid()
        defer { window.close() }
        let cells = SyntheticComponents.glyphCells(count: 12)
        grid.apply(GridContent(sections: [GridSection(title: "Smileys", cells: cells)]))
        let plain = try #require(grid.drawnText().headers.first)
        grid.apply(GridContent(sections: [GridSection(title: "Smileys", cells: cells, count: 12)]))
        GridViewTests().render(grid)
        let counted = try #require(grid.drawnText().headers.first)
        #expect(counted.width > plain.width + 6)
        let header = grid.accessibilityChildren()?.first as? NSAccessibilityElement
        #expect(header?.accessibilityLabel() == "Smileys, 12")
        let passes = grid.displayPasses
        grid.apply(GridContent(sections: [GridSection(title: "Smileys", cells: cells, count: 11)]))
        GridViewTests().render(grid)
        #expect(grid.displayPasses == passes + 1, "a new count redraws its header")
        #expect(grid.cellsDrawnInLastPass == 0)
    }

    // MARK: Helpers

    func typeset(_ row: ListRow, theme: ResolvedTheme) -> RowTypeset {
        RowTypesetter.typeset(
            row, width: 760, height: 44, style: .oneLine, emphasizesMatches: false, theme: theme, scale: 2)
    }

    static func colors(of line: CTLine) -> [CGColor] {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return runs.compactMap { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTForegroundColorAttributeName as String] else { return nil }
            return (value as! CGColor)
        }
    }

    static func ratio(_ color: CGColor, theme: ResolvedTheme) -> Double {
        let sRGB = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
        let parts = sRGB.components!.map(Double.init)
        let reference = theme.isDark ? LegibleColor.darkReferenceLuminance : LegibleColor.lightReferenceLuminance
        return LegibleColor.ratio(LegibleColor.luminance(red: parts[0], green: parts[1], blue: parts[2]), reference)
    }

    static func hue(_ color: CGColor) -> CGFloat {
        NSColor(cgColor: color)?.usingColorSpace(.sRGB)?.hueComponent ?? -1
    }
}
