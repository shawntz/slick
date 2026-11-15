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
