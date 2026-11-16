import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// One surface and one list through every built-in theme in turn, as the capture tools and a user
/// who tries each theme in Settings use them. The list must draw where its lens is after every
/// switch. Windows stay off every screen and never take key status.
@Suite(.timeLimit(.minutes(1)))
struct ThemeSwitchListTests {
    /// The root list, then the components' "list-sections" state: a two-line query, the same rows
    /// split under two headers, and the second row selected.
    private func showSections(_ list: ResultListView, catalog: SyntheticCatalog) {
        list.apply(catalog.rootContent())
        list.select(0, animated: false)
        var content = catalog.content(for: "a", rowStyle: .twoLine)
        list.apply(content)
        list.select(0, animated: false)
        content.rowStyle = .oneLine
        content.rowStyle = .twoLine
        if let rows = content.sections.first?.rows, rows.count > 4 {
            content.sections = [
                ListSection(title: "Applications", rows: Array(rows.prefix(3))),
                ListSection(title: "Commands", rows: Array(rows.dropFirst(3).prefix(5)), count: rows.count - 3),
            ]
        }
        list.apply(content)
        list.select(1, animated: false)
    }

    @Test(arguments: [false, true])
    func theListDrawsUnderItsLensAfterEverySwitch(dark: Bool) throws {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let catalog = SyntheticCatalog()
        let list = ResultListView()
        let other = EmptyStateView()
        surface.setContent(list, animated: false)
        surface.panel.orderFrontRegardless()
        for named in ThemeStore.builtInThemes + ThemeStore.builtInThemes.reversed() {
            surface.theme = named.theme
            for _ in 0..<3 {
                // Another page in between, then back to the list, as each captured state does.
                surface.setContent(other, animated: false)
                surface.setContent(list, animated: false)
                showSections(list, catalog: catalog)
                surface.updateHeight(animated: false)
                surface.rootView.layoutSubtreeIfNeeded()
                list.displayIfNeeded()

                let theme = named.name
                #expect(list.scrollOffset == 0, "\(theme)")
                #expect(list.frame.minY == surface.contentTop, "\(theme)")
                #expect(list.frame.height == CGFloat(named.theme.panel.maxContentHeight), "\(theme)")
                #expect(list.headerTextFrames().first.map { $0.minY >= 0 } == true, "\(theme): first header shows")
                let row = try #require(list.rowRect(1))
                let inset = CGFloat(named.theme.lens.horizontalInset)
                let expected = list.convert(row.insetBy(dx: inset, dy: 0), to: surface.lens.view.superview)
                #expect(!surface.lens.isHidden, "\(theme)")
                #expect(surface.lens.view.frame == expected, "\(theme): the lens sits on row 1")
                #expect(list.layoutModel.rowCount == 8, "\(theme)")
            }
        }
    }

    /// On screen, AppKit sizes a view's backing to what it draws, and after the glass had been
    /// short it placed the list's taller drawing a header height too high. Every draw of the list,
    /// the grid, the card list and the metadata table therefore touches both corners of its
    /// bounds. Off screen AppKit builds no such backing, so this checks the drawing itself.
    @Test func everyDrawSpansTheWholeBounds() throws {
        let (list, window) = TestSupport.makeList()
        defer { window.close() }
        list.apply(ListContent(sections: [ListSection(rows: TestSupport.rows(["Notes"]))]))
        let width = Int(list.bounds.width)
        let height = Int(list.bounds.height)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        list.draw(list.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        let pixels = try #require(image.dataProvider?.data as Data?)
        // The bitmap's rows run top-down; the context's y runs bottom-up.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(height - 1 - y) * image.bytesPerRow + x * 4 + 3] }
        #expect(alpha(0, 0) == 0 && alpha(width - 1, height - 1) == 0, "both corners touched")
        #expect(alpha(width - 1, 0) == 255 && alpha(width / 2, height / 2) == 255, "the rest of the red stays")
    }
}
