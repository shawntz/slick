import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// Beam's results container and action bar, the hidden glass the summoner renders, and the order
/// accessibility reads the pieces in. Windows stay off every screen and never take key status.
@Suite(.timeLimit(.minutes(1)))
struct GlassPiecesTests {
    private func beam(content: Bool = true) -> (LauncherSurface, ResultListView) {
        let surface = TestSupport.makeSurface()
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        surface.theme = .beam
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        let list = ResultListView()
        if content {
            surface.setContent(list, animated: false)
            list.apply(SyntheticCatalog().rootContent())
            surface.updateHeight(animated: false)
        }
        return (surface, list)
    }

    /// Beam's results end under the last row, as the reference's do; a toast brings the bar and
    /// the room for it, and takes both away again.
    @Test func beamsActionBarShowsOnlyForAToast() {
        let (surface, list) = beam()
        defer { surface.panel.close() }
        let rows = list.preferredContentHeight(limit: 10_000)
        #expect(surface.actionBar.isHidden)
        #expect(surface.resultsGlass.frame.height == rows)
        surface.actionBar.show(ActionBarToast(.success, "Copied"))
        #expect(!surface.actionBar.isHidden)
        #expect(surface.resultsGlass.frame.height == rows + CGFloat(Theme.beam.actionBar.height))
        #expect(surface.actionBar.frame.maxY == surface.resultsGlass.frame.height)
        surface.actionBar.show(nil)
        #expect(surface.actionBar.isHidden)
        #expect(surface.resultsGlass.frame.height == rows)
        // The window has room for the bar.
        let tallest = Theme.beam.maxGlassHeight
        #expect(tallest == Theme.beam.glassHeight(contentHeight: Theme.beam.panel.maxContentHeight, showsToast: true))
    }

    @Test func standardKeepsItsBarWithOrWithoutAToast() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let list = ResultListView()
        surface.setContent(list, animated: false)
        list.apply(SyntheticCatalog().rootContent())
        surface.updateHeight(animated: false)
        let height = surface.glass.frame.height
        #expect(!surface.actionBar.isHidden)
        surface.actionBar.show(ActionBarToast(.info, "Saved"))
        #expect(surface.glass.frame.height == height)
        surface.actionBar.show(nil)
        #expect(surface.glass.frame.height == height && !surface.actionBar.isHidden)
    }

    /// The hidden container is laid out at a full height from the start, so the summoner can
    /// render it while the panel is invisible.
    @Test func theHiddenContainerHasAFullFrameFromTheStart() {
        let (surface, _) = beam(content: false)
        defer { surface.panel.close() }
        #expect(surface.resultsGlass.alphaValue == 0)
        #expect(surface.resultsGlass.frame.height == CGFloat(Theme.beam.panel.maxContentHeight))
        var shown: [CGFloat] = []
        surface.withEveryPieceShown { shown = surface.glassPieces.map(\.alphaValue) }
        #expect(shown == [1, 1])
        #expect(surface.resultsGlass.alphaValue == 0, "hidden again after")
    }

    /// The summoner renders every piece at pre-warm, and again after a theme change adds or
    /// restyles one, whether the panel is hidden then or shows and is dismissed later.
    @Test func theSummonerRendersNewGlassWhileThePanelIsInvisible() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        let summoner = Summoner(surface: surface)
        summoner.followsPointerScreen = false
        summoner.takesKeyStatus = false
        summoner.prewarm()
        #expect(summoner.hiddenGlassRenders == 1)
        surface.theme = .graphite
        #expect(summoner.hiddenGlassRenders == 1, "colours alone add no glass")
        surface.theme = .beam
        #expect(summoner.hiddenGlassRenders == 2, "a second piece")
        #expect(surface.rootView.layer?.opacity == 0 && surface.panel.alphaValue == 1, "still invisible")
        summoner.summon()
        surface.theme = .clear
        #expect(summoner.hiddenGlassRenders == 2, "not while it shows")
        summoner.dismiss(returnFocus: false)
        #expect(summoner.hiddenGlassRenders == 3, "at the next dismiss")
        #expect(surface.rootView.layer?.opacity == 0)
    }

    /// Accessibility reads the search field before the results, though the results container
    /// sits under the query row's glass in the view order.
    @Test func accessibilityReadsTheQueryRowFirst() throws {
        let (surface, list) = beam()
        defer { surface.panel.close() }
        // AppKit lists the list view and the search field's cell, the list first unless reordered.
        let children = try #require(surface.rootView.accessibilityChildren())
        func index(of view: NSView) -> Int? {
            children.firstIndex { child in
                guard let child = (child as? NSView) ?? (child as? NSCell)?.controlView else { return false }
                return child === view || view.isDescendant(of: child) || child.isDescendant(of: view)
            }
        }
        let field = try #require(index(of: surface.queryField.textField))
        let results = try #require(index(of: list))
        #expect(field < results)
    }

    /// Under Reduce Transparency Beam drops its tints and the query row's shade, so the system's
    /// opaque glass shows, and keeps its two pieces, its rim and its shadow.
    @Test func beamUnderReduceTransparency() {
        let (surface, _) = beam()
        defer { surface.panel.close() }
        surface.accessibilityOverride = DisplayAccessibility(reduceTransparency: true)
        #expect(surface.glassPieces.count == 2)
        #expect(surface.glassPieces.allSatisfy { $0.style == .regular && $0.tintColor == nil })
        #expect(surface.resolvedTheme.fieldShade == nil)
        #expect(surface.resolvedTheme.rim != nil && surface.resolvedTheme.shadow != nil)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        #expect(surface.glass.tintColor != nil && surface.resolvedTheme.fieldShade != nil)
    }
}
