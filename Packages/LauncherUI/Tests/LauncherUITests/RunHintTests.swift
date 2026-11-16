import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// The Command-digit hints at the end of the first nine rows, as Spotlight shows them.
@Suite(.timeLimit(.minutes(1)))
struct RunHintTests {
    static var spotlight: ResolvedTheme {
        _ = NSApplication.shared
        return ResolvedTheme(
            theme: .spotlight, appearance: NSAppearance(named: .darkAqua)!, accessibility: DisplayAccessibility())
    }

    static func titles(_ count: Int) -> [String] { (1...count).map { "Item \($0)" } }

    @Test func theFirstNineRowsAcrossSectionsShowTheirChord() throws {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        list.apply(
            ListContent(sections: [
                ListSection(title: "Suggested", rows: TestSupport.rows(Self.titles(4))),
                ListSection(title: "Favorites", rows: TestSupport.rows(Self.titles(8), idBase: 100)),
            ]))
        list.select(11, animated: false)
        list.scroll(to: 0)
        let width = list.bounds.width
        for index in 0..<9 {
            let hint = try #require(list.textFrames(row: index)?.runHint, "row \(index)")
            #expect(abs(hint.maxX - (width - 36)) < 1, "the hint ends at the trailing inset")
        }
        for index in 9..<12 { #expect(list.textFrames(row: index)?.runHint == nil) }
        #expect(RunHint.text(forRow: 0) == "\u{2318}1" && RunHint.text(forRow: 8) == "\u{2318}9")
        #expect(RunHint.text(forRow: 9) == nil && RunHint.text(forRow: -1) == nil)
    }

    /// A page whose rows no chord runs, such as the one that asks for a command's argument, shows
    /// no hint even in a theme that shows them.
    @Test func aPageThatRunsNoRowByChordShowsNone() {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["Set Volume"]))], showsRunHints: false))
        #expect(list.textFrames(row: 0)?.runHint == nil)
        #expect(list.runHint(forRow: 0) == nil)
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["Set Volume"]))]))
        #expect(list.textFrames(row: 0)?.runHint != nil, "the same rows on a page that runs them")
    }

    /// A row's own shortcut beside the hint would read as one chord, so it keeps twice the gap.
    @Test func aRowsOwnShortcutKeepsItsDistanceFromTheHint() throws {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        var rows = TestSupport.rows(["Window Left", "Window Right"])
        rows[0].accessories = [.keycaps(["\u{2318}", "4"])]
        rows[1].accessories = [.text("Yesterday")]
        list.apply(ListContent(sections: [ListSection(rows: rows)]))
        let gap = CGFloat(Theme.spotlight.list.accessoryGap)
        let keyed = try #require(list.textFrames(row: 0))
        let hint = try #require(keyed.runHint)
        let keys = try #require(keyed.capsules.map(\.maxX).max())
        #expect(hint.minX - keys >= gap * 2 - 1)
        let plain = try #require(list.textFrames(row: 1))
        let text = try #require(plain.accessories.map(\.maxX).max())
        #expect(try #require(plain.runHint).minX - text < gap * 2 - 1)
    }

    @Test func aThemeWithoutHintsShowsNone() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(Self.titles(3)))]))
        #expect(list.textFrames(row: 0)?.runHint == nil)
        #expect(list.runHint(forRow: 0) == nil)
    }

    @Test func theRowsOwnAccessoriesGoBeforeTheHint() throws {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        var row = ListRow(id: 1, title: "Clipboard History", subtitle: "Command")
        row.accessories = [.text("Pinned"), .keycaps(["⌥", "V"])]
        list.apply(ListContent(sections: [ListSection(rows: [row])]))
        let frames = try #require(list.textFrames(row: 0))
        let hint = try #require(frames.runHint)
        let others = frames.accessories + frames.capsules
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.maxX < hint.minX })
        #expect(frames.title.maxX < others.map(\.minX).min()!)
    }

    @Test func aRowThatMovesUpGainsItsHint() throws {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        let rows = TestSupport.rows(Self.titles(12))
        list.apply(ListContent(sections: [ListSection(rows: rows)]))
        list.displayIfNeeded()
        #expect(list.textFrames(row: 9)?.runHint == nil)
        var moved = rows
        moved.insert(moved.remove(at: 9), at: 2)
        list.apply(ListContent(sections: [ListSection(rows: moved)]))
        list.displayIfNeeded()
        #expect(list.row(at: 2)?.title == "Item 10")
        #expect(list.textFrames(row: 2)?.runHint != nil)
        #expect(list.rowsDrawnInLastPass >= 8, "every row from the move down changed its place")
    }

    @Test func accessibilityReadsTheChordAsHelp() throws {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        var row = ListRow(id: 1, title: "Notes", subtitle: "Application")
        row.accessories = [.text("Running")]
        list.apply(ListContent(sections: [ListSection(rows: [row] + TestSupport.rows(Self.titles(10), idBase: 10))]))
        let rows = try #require(list.accessibilityChildren()?.compactMap { $0 as? ResultRowElement })
        #expect(rows[0].accessibilityHelp() == "Running, \u{2318}1")
        #expect(rows[8].accessibilityHelp() == "\u{2318}9")
        #expect(rows[9].accessibilityHelp() == nil)
    }

    @Test func nineHintLinesAreMadeOnceAndReused() {
        let (list, window) = TestSupport.makeList(theme: Self.spotlight)
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(Self.titles(9)))]))
        list.displayIfNeeded()
        let misses = list.lineCache.misses
        var renamed = list.content
        for index in renamed.sections[0].rows.indices { renamed.sections[0].rows[index].title += " Again" }
        list.apply(renamed)
        list.displayIfNeeded()
        // Nine new titles; the hints and subtitles come from the cache.
        #expect(list.lineCache.misses - misses == 9)
    }
}
