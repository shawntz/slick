import AppKit
import LauncherUI
import Testing

@testable import SettingsUI

/// The theme preview shows the glass as the panel draws it: its style, and one piece or two.
/// Windows are never ordered in. Every preview is drawn for fixed accessibility settings, so a Mac
/// with Reduce Transparency on, as a CI runner has, sees what any other Mac sees.
@Suite(.timeLimit(.minutes(1)))
struct ThemePreviewTests {
    private func preview(_ theme: Theme) -> (ThemePreviewView, NSWindow) {
        _ = NSApplication.shared
        let size = ThemePreviewView.logicalSize(for: theme)
        let view = ThemePreviewView(frame: CGRect(origin: .zero, size: size))
        view.accessibilityOverride = DisplayAccessibility()
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.apply(theme: theme)
        return (view, window)
    }

    @Test func aSplitThemeShowsTheQueryRowApartFromTheResults() throws {
        let (view, window) = preview(.beam)
        defer { window.close() }
        let pieces = view.glassPieces
        try #require(pieces.count == 2)
        let field = pieces[0].frame
        let results = pieces[1].frame
        #expect(Double(field.height) == Theme.beam.queryRow.height)
        #expect(Double(pieces[0].cornerRadius) == Theme.beam.fieldCornerRadius)
        #expect(Double(results.minY - field.maxY) == Theme.beam.panel.fieldGap)
        #expect(view.queryField.isDescendant(of: pieces[0]))
        #expect(view.list.isDescendant(of: pieces[1]) && view.lens.view.isDescendant(of: pieces[1]))
        // Beam shows its action bar only for a toast, so the preview has none.
        #expect(view.actionBar.isHidden)
        #expect(view.list.frame.maxY <= results.height)
    }

    @Test func clearGlassAndOnePieceForClearAndBackAgain() throws {
        let (view, window) = preview(.clear)
        defer { window.close() }
        #expect(view.glassPieces.count == 1)
        #expect(view.glassPieces[0].style == .clear)
        #expect(view.glassPieces[0].tintColor == nil)
        view.apply(theme: .beam)
        #expect(view.glassPieces.count == 2 && view.glassPieces.allSatisfy { $0.style == .regular })
        view.apply(theme: .standard)
        #expect(view.glassPieces.count == 1 && view.glassPieces[0].style == .regular)
        #expect(view.list.isDescendant(of: view.glassPieces[0]))
        #expect(!view.actionBar.isHidden)
    }

    @Test func reduceTransparencyDrawsEveryThemeInRegularGlassWithNoTint() throws {
        let (view, window) = preview(.clear)
        defer { window.close() }
        view.accessibilityOverride = DisplayAccessibility(reduceTransparency: true)
        #expect(view.glassPieces[0].style == .regular && view.glassPieces[0].tintColor == nil)
        view.apply(theme: .standard)
        #expect(view.glassPieces[0].style == .regular && view.glassPieces[0].tintColor == nil)
        view.accessibilityOverride = DisplayAccessibility()
        #expect(view.glassPieces[0].style == .regular && view.glassPieces[0].tintColor != nil)
    }
}
