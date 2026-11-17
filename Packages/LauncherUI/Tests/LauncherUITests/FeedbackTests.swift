import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct FeedbackTests {
    @Test func theHUDNeverTakesKeyOrClicks() {
        _ = NSApplication.shared
        let hud = HUDWindow()
        defer { hud.close() }
        #expect(!hud.canBecomeKey)
        #expect(!hud.canBecomeMain)
        #expect(hud.ignoresMouseEvents)
        #expect(hud.styleMask.contains(.nonactivatingPanel))
        #expect(hud.level.rawValue > NSWindow.Level.floating.rawValue)
    }

    @Test func theHUDFitsItsTextAndSitsAtTheBottomCentre() throws {
        _ = NSApplication.shared
        let hud = HUDWindow()
        defer { hud.hide() }
        let screen = TestSupport.offscreen
        hud.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        hud.setFrameOrigin(screen.origin)
        hud.prewarm()
        hud.show(HUDContent("Copied to Clipboard", symbolName: "checkmark.circle.fill"), on: screen)
        let label = try #require(hud.textLabel)
        label.superview?.layoutSubtreeIfNeeded()
        let needed = (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width
        #expect(Double(label.frame.width) >= Double(needed))
        #expect(abs(Double(hud.frame.midX - screen.midX)) <= 0.5)
        let feedback = Theme.standard.feedback
        #expect(Double(hud.frame.minY) == Double(screen.minY) + feedback.hudBottomMargin - feedback.hudShadowInset)
        #expect(hud.content == HUDContent("Copied to Clipboard", symbolName: "checkmark.circle.fill"))
    }

    /// The appearance setting can draw the HUD light on a dark Mac, or dark on a light one. A theme
    /// whose HUD tint is a system colour then fills the capsule with that colour as the HUD's own
    /// appearance resolves it, not as the app's does.
    /// AppKit fixes a system colour with less than full alpha when it makes it, and keeps one at
    /// full alpha dynamic until it is turned into a CGColor, so both kinds are checked.
    @Test(arguments: [0.5, 1])
    func theHUDFillsItsCapsuleForItsOwnAppearance(alpha: Double) throws {
        _ = NSApplication.shared
        let appIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = try #require(NSAppearance(named: appIsDark ? .aqua : .darkAqua))
        let tint = ThemeColor(.label, alpha: alpha)
        var theme = Theme.standard
        theme.clarity = 1
        theme.light.hudTint = tint
        theme.dark.hudTint = tint
        let hud = HUDWindow(theme: theme)
        defer { hud.close() }
        hud.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        hud.appearance = appearance
        hud.setFrameOrigin(TestSupport.offscreen.origin)
        hud.prewarm()

        let expected = tint.cgColor(in: appearance)
        #expect(expected != tint.cgColor(in: NSApp.effectiveAppearance), "label differs between light and dark")
        #expect(hud.backingColor == expected)
    }

    @Test func theEmptyStateAsksForItsHeightOnlyWithATitle() {
        let view = EmptyStateView(frame: CGRect(x: 0, y: 0, width: 760, height: 500))
        view.apply(TestSupport.lightTheme)
        #expect(view.preferredContentHeight(limit: 500) == 0)
        var heightChanges = 0
        view.contentHeightDidChange = { heightChanges += 1 }
        view.apply(EmptyStateContent(symbolName: "tray", title: "Nothing Here", hint: "Try another word."))
        #expect(Double(view.preferredContentHeight(limit: 500)) == Theme.standard.feedback.emptyStateHeight)
        #expect(heightChanges == 1)
    }

    @Test func theLoadingBarSweepsAndStops() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let bar = surface.glass.contentView?.subviews.compactMap { $0 as? LoadingBarView }.first
        #expect(bar?.isHidden == true)
        surface.isLoading = true
        #expect(bar?.isAnimating == true)
        #expect(bar?.isHidden == false)
        surface.isLoading = false
        #expect(bar?.isHidden == true)
        #expect(bar?.isAnimating == false)
    }
}
