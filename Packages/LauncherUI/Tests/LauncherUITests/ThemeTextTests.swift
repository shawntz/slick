import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// How Spotlight and Glass treat text outside the rows: the query field, the empty state, the
/// metadata table and the list beside a detail pane. Windows stay off every screen.
@Suite(.timeLimit(.minutes(1)))
struct ThemeTextTests {
    private static func resolved(_ theme: Theme, dark: Bool) -> ResolvedTheme {
        _ = NSApplication.shared
        return ResolvedTheme(
            theme: theme, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!,
            accessibility: DisplayAccessibility())
    }

    /// Glass's query field carries the halo the rows carry, on the typed text, the placeholder,
    /// the ghost and the magnifier. Over a white page in dark mode they vanished without it.
    @Test func clearsQueryFieldTakesTheHalo() throws {
        let field = QueryField(frame: CGRect(x: 0, y: 0, width: 600, height: 60))
        let clear = Self.resolved(.glass, dark: true)
        field.apply(clear)
        for view in [field.textField, field.glyphView] as [NSView] {
            let shadow = try #require(view.shadow)
            #expect(shadow.shadowColor?.alphaComponent == CGFloat(Theme.glass.dark.textHalo?.alpha ?? 0))
            #expect(shadow.shadowBlurRadius == CGFloat(Theme.glass.dark.textHaloRadius) && shadow.shadowOffset == .zero)
        }
        // Vibrant text cannot carry a dark halo, so under one the field takes the theme's colours.
        #expect(field.textField.textColor != .labelColor)
        #expect(field.textField.textColor?.cgColor.alpha == clear.title.alpha)
        field.apply(Self.resolved(.standard, dark: true))
        #expect(field.textField.shadow == nil && field.glyphView.shadow == nil)
        #expect(field.textField.textColor == .labelColor && field.glyphView.contentTintColor == .secondaryLabelColor)
    }

    /// Spotlight's placeholder is brighter than the system's tertiary label, as the reference's is,
    /// and stays a system colour so the field keeps its vibrancy.
    @Test func theThemeSetsThePlaceholderAndTheEmptySymbol() throws {
        let field = QueryField(frame: CGRect(x: 0, y: 0, width: 600, height: 87))
        field.placeholder = "Search"
        field.apply(Self.resolved(.spotlight, dark: true))
        let spotlightColor = try #require(
            field.textField.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? NSColor)
        #expect(spotlightColor == .secondaryLabelColor)
        field.apply(Self.resolved(.standard, dark: true))
        let standardColor = try #require(
            field.textField.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? NSColor)
        #expect(standardColor == .tertiaryLabelColor)
        #expect(Self.resolved(.spotlight, dark: true).emptySymbol == .labelColor)
        #expect(Self.resolved(.standard, dark: true).emptySymbol == .tertiaryLabelColor)
    }

    /// Only text takes the halo in the metadata table. A translucent swatch is drawn once and
    /// casts no shadow, so its own alpha shows.
    @Test func aSwatchUnderClearsHaloIsDrawnOnceWithoutAShadow() throws {
        let size = CGSize(width: 320, height: 40)
        let view = MetadataView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: CGRect(origin: TestSupport.offscreen.origin, size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.apply(Self.resolved(.glass, dark: false))
        view.items = [.color("Color", ThemeColor(red: 1, green: 0, blue: 0, alpha: 0.5), text: "Red")]
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // The reddest pixel is inside the swatch, away from the text and its halo.
        var best: (red: CGFloat, alpha: CGFloat) = (0, 0)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let redness = color.redComponent * color.alphaComponent - color.greenComponent * color.alphaComponent
                if redness > best.red { best = (redness, color.alphaComponent) }
            }
        }
        #expect(best.red > 0.3)
        #expect(abs(best.alpha - 0.5) < 0.06, "drawn once, no halo under it: alpha \(best.alpha)")
    }

    /// Beside a detail pane Spotlight's rows lose 81 pt to their indent and more to the run hint, so
    /// its list takes a larger share of the width: its titles keep at least Standard's room.
    @Test func spotlightsTitlesBesideADetailPaneHaveStandardsRoom() throws {
        func room(_ theme: Theme) throws -> CGFloat {
            let split = ListDetailView(frame: CGRect(x: 0, y: 0, width: theme.panel.width, height: 400))
            let window = NSWindow(
                contentRect: CGRect(origin: TestSupport.offscreen.origin, size: split.frame.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = split
            split.apply(Self.resolved(theme, dark: true))
            split.layoutSubtreeIfNeeded()
            var row = ListRow(id: 1, title: String(repeating: "Meeting moved to Thursday ", count: 4))
            row.accessories = [.text("Yesterday")]
            split.list.apply(ListContent(sections: [ListSection(rows: [row])]))
            let frames = try #require(split.list.textFrames(row: 0))
            #expect(frames.runHint == nil, "no hint beside a detail pane")
            return frames.title.width
        }
        #expect(try room(.spotlight) >= room(.standard) - 1)
    }
}
