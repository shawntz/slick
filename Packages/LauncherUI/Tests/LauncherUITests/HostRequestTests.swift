import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// What Host asked for in round 3: scroll reports, the notice banner, the confirm card's checkbox,
/// toast buttons and the info style, and the caret colour.
@Suite struct HostRequestTests {
    @Test func theListReportsVisibleRowsWhenItScrolls() {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(
            ListContent(sections: [ListSection(title: nil, rows: TestSupport.rows((0..<30).map { "Row \($0)" }))]))
        #expect(list.visibleRows.lowerBound == 0)
        #expect(list.visibleRows.count >= Theme.standard.list.maxVisibleRows)
        var reports: [Range<Int>] = []
        list.onVisibleRowsChange = { reports.append($0) }
        list.scroll(to: CGFloat(Theme.standard.list.rowHeight) * 5)
        #expect(reports.count == 1)
        #expect(reports.last == list.visibleRows)
        #expect(list.visibleRows.lowerBound >= 4)
        // The same rows again is not a change.
        list.scroll(to: CGFloat(Theme.standard.list.rowHeight) * 5)
        #expect(reports.count == 1)
        // Revealing a selection scrolls, and so reports.
        list.select(29, animated: false)
        #expect(reports.count == 2)
        #expect(reports.last?.contains(29) == true)
        // New content does not report.
        list.apply(ListContent(sections: [ListSection(title: nil, rows: TestSupport.rows(["Only"]))]))
        #expect(reports.count == 2)
        #expect(list.visibleRows == 0..<1)
    }

    @Test func theGridReportsVisibleCellsWhenItScrolls() {
        let (grid, window) = GridViewTests().makeGrid()
        defer { window.close() }
        grid.apply(GridViewTests().content(SyntheticComponents.glyphCells(count: 400)))
        let first = grid.visibleCells
        #expect(first.lowerBound == 0 && !first.isEmpty)
        var reports: [Range<Int>] = []
        grid.onVisibleCellsChange = { reports.append($0) }
        grid.scroll(to: 400)
        #expect(reports.count == 1)
        #expect(reports.last == grid.visibleCells)
        #expect(grid.visibleCells.lowerBound > first.lowerBound)
        grid.select(399, animated: false)
        #expect(reports.last?.contains(399) == true)
    }

    @Test func theBannerDrawsItsPartsAndPressesOnlyWithAButton() throws {
        let banner = NoticeBanner(frame: CGRect(x: 0, y: 0, width: 760, height: 52))
        banner.apply(TestSupport.lightTheme)
        #expect(NoticeBanner.preferredHeight(for: TestSupport.lightTheme) == 52)
        var presses = 0
        banner.onPress = { presses += 1 }
        banner.apply(NoticeContent(title: "Files are still indexing", message: "Results may be missing"))
        #expect(!banner.accessibilityPerformPress())
        #expect(presses == 0)
        #expect(banner.drawnText().titles.count == 1)
        #expect(banner.drawnText().secondary.count == 1)
        #expect(banner.drawnText().capsules.isEmpty)
        #expect(banner.accessibilityLabel() == "Files are still indexing, Results may be missing")

        banner.apply(NoticeContent(title: "Full Disk Access is off", buttonTitle: "Grant Access"))
        #expect(banner.accessibilityRole() == .button)
        #expect(banner.accessibilityPerformPress())
        #expect(presses == 1)
        let drawn = banner.drawnText()
        let title = try #require(drawn.titles.first)
        let button = try #require(drawn.capsules.first)
        #expect(title.maxX < button.minX)
        #expect(button.maxX <= banner.bounds.maxX)
    }

    @Test func theConfirmCardOffersDontAskAgain() throws {
        let surface = OverlayTests().makeSurface()
        defer { surface.panel.close() }
        let card = ConfirmCardView(
            content: ConfirmContent(
                title: "Clear history?", confirmTitle: "Clear", isDestructive: true,
                suppressionTitle: "Don't ask again"))
        var confirmedWith: Bool?
        card.onConfirm = { [weak card] in confirmedWith = card?.isSuppressionChecked }
        surface.present(card)
        let box = try #require(card.suppression)
        #expect(!card.isSuppressionChecked)
        card.keyDown(with: try #require(Self.key(" ", code: 49)))
        #expect(card.isSuppressionChecked)
        card.layoutSubtreeIfNeeded()
        #expect(box.frame.maxX < card.cancelButton.frame.minX)
        #expect(box.frame.width > 0)
        #expect(card.drawnText().titles.count == 2)
        card.keyDown(with: try #require(Self.key("\r", code: 36)))
        #expect(confirmedWith == true)

        let plain = ConfirmCardView(content: ConfirmContent(title: "Quit?", confirmTitle: "Quit"))
        #expect(plain.suppression == nil)
        #expect(!plain.isSuppressionChecked)
    }

    @Test func toastsTakeAnInfoStyleAndAButton() {
        let bar = ActionBar(frame: CGRect(x: 0, y: 0, width: 760, height: 40))
        bar.apply(TestSupport.lightTheme)
        bar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open"))
        var pressed = 0
        bar.onToastButton = { pressed += 1 }
        bar.show(ActionBarToast(.info, "Index rebuilt"))
        bar.layoutSubtreeIfNeeded()
        #expect(bar.toastButton.isHidden)

        bar.show(ActionBarToast(.failure, "Could not copy", buttonTitle: "Show Details", buttonKeys: ["⌘", "D"]))
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.toastButton.isHidden)
        #expect(bar.toastButton.title == "Show Details")
        #expect(bar.toastButton.key == "⌘D")
        #expect(bar.toastButton.frame.width > 0)
        #expect(bar.toastButton.accessibilityPerformPress())
        #expect(pressed == 1)

        bar.show(nil)
        #expect(bar.toastButton.isHidden)
    }

    @Test func theCaretTakesTheThemeAccent() throws {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.theme = .violet
        let expected = try #require(NSColor(cgColor: surface.resolvedTheme.accent)?.usingColorSpace(.sRGB))
        let caret = try #require(surface.panel.queryFieldEditor.insertionPointColor.usingColorSpace(.sRGB))
        #expect(abs(caret.redComponent - 0x87 / 255) < 0.01)
        #expect(abs(caret.blueComponent - expected.blueComponent) < 0.01)
    }

    static func key(_ characters: String, code: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
}
