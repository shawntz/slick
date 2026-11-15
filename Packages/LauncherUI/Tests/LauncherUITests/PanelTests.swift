import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

@Suite(.timeLimit(.minutes(1)))
struct PanelTests {
    @Test func panelFlagsFollowTheGlassRules() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let panel = surface.panel
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque)
        #expect(!panel.hasShadow)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.animationBehavior == .none)
        #expect(panel.collectionBehavior.contains(.transient))
    }

    @Test func oneGlassViewWithTheThemeRadius() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        #expect(surface.glass.style == .regular)
        #expect(Double(surface.glass.cornerRadius) == Theme.standard.panel.cornerRadius)
        if #available(macOS 27, *) { #expect(surface.glass.effectIsInteractive == false) }
        // The lens sits directly in the glass content view, under the content.
        #expect(surface.lens.view.superview === surface.glass.contentView)
    }

    @Test func compactUntilThereIsContent() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        #expect(Double(surface.glass.frame.height) == Theme.standard.queryRow.height)
        #expect(surface.actionBar.isHidden)
        let list = ResultListView()
        surface.setContent(list, animated: false)
        list.apply(SyntheticCatalog().rootContent())
        // The list asked for an animated resize; finish it at once.
        surface.updateHeight(animated: false)
        #expect(surface.glass.frame.height == surface.targetGlassHeight)
        #expect(Double(surface.glass.frame.height) > Theme.standard.queryRow.height)
        #expect(!surface.actionBar.isHidden)
        #expect(surface.actionBar.frame.maxY == surface.glass.frame.height)
    }

    @Test func darkAppearanceDarkensTheTint() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.panel.appearance = NSAppearance(named: .darkAqua)
        surface.refreshTheme()
        #expect(surface.resolvedTheme.isDark)
        #expect(surface.glass.tintColor == surface.resolvedTheme.glassTint)
    }

    @Test func reduceTransparencyUsesTheSystemGlass() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.accessibilityOverride = DisplayAccessibility(reduceTransparency: true)
        #expect(surface.glass.tintColor == nil)
    }

    @Test func summonFlipsOpacityAndAccessibility() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let summoner = Summoner(surface: surface)
        summoner.followsPointerScreen = false
        summoner.takesKeyStatus = false
        summoner.prewarm()
        #expect(surface.panel.isVisible)
        #expect(surface.rootView.layer?.opacity == 0)
        #expect(surface.rootView.isAccessibilityHidden())
        #expect(surface.panel.firstResponder === surface.panel.queryFieldEditor)

        var prepared = 0
        summoner.prepareNext = { prepared += 1 }
        summoner.summon()
        #expect(summoner.isShown)
        #expect(surface.rootView.layer?.opacity == 1)
        #expect(!surface.rootView.isAccessibilityHidden())
        #expect(!surface.panel.isKeyWindow)
        summoner.dismiss(returnFocus: false)
        #expect(surface.rootView.layer?.opacity == 0)
        #expect(surface.rootView.isAccessibilityHidden())
        #expect(prepared == 1)
    }

    @Test func actionBarShowsTheActionsTitleFromTheFirstUpdate() {
        let bar = ActionBar(frame: CGRect(x: 0, y: 0, width: 760, height: 40))
        bar.apply(TestSupport.lightTheme)
        bar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open"))
        #expect(bar.actionsTitle.stringValue == "Actions")
        #expect(!bar.actionsTitle.isHidden)
    }

    @Test func actionBarShowsAndClearsAToast() {
        let bar = ActionBar(frame: CGRect(x: 0, y: 0, width: 760, height: 40))
        bar.apply(TestSupport.lightTheme)
        bar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open"))
        bar.show(ActionBarToast(.success, "Copied"))
        #expect(bar.toast == ActionBarToast(.success, "Copied"))
        bar.show(nil)
        #expect(bar.toast == nil)
    }
}
