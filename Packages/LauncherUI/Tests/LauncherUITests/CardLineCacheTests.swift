import AppKit
import LauncherUITesting
import Testing

@_spi(Testing) @testable import LauncherUI

/// The action card keeps its typeset titles, headers and keycaps, so opening it again or
/// filtering it does not typeset them again. Off screen, never key.
@Suite(.timeLimit(.minutes(1)))
struct CardLineCacheTests {
    private func presentedCard() -> (LauncherSurface, ActionCardView) {
        let surface = TestSupport.makeSurface()
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let list = ResultListView()
        surface.setContent(list, animated: false)
        list.apply(SyntheticCatalog().rootContent())
        let card = ActionCardView(content: SyntheticComponents.actions)
        surface.present(card)
        draw(card)
        return (surface, card)
    }

    private func draw(_ card: ActionCardView) {
        card.list.needsDisplay = true
        card.window?.displayIfNeeded()
        CATransaction.flush()
    }

    @Test func aSecondDrawTypesetsNothing() {
        let (surface, card) = presentedCard()
        defer { surface.panel.close() }
        let cache = card.list.lineCache
        // Seven titles, two section titles and eleven distinct keys, some shared.
        #expect(cache.misses > 0)
        let misses = cache.misses
        let hits = cache.hits
        draw(card)
        #expect(cache.misses == misses)
        #expect(cache.hits > hits)
    }

    @Test func reopeningAndFilteringReuseTheLines() {
        let (surface, card) = presentedCard()
        defer { surface.panel.close() }
        let cache = card.list.lineCache
        let misses = cache.misses
        surface.dismissOverlay()
        surface.present(card)
        draw(card)
        #expect(cache.misses == misses, "the same actions typeset nothing again")
        surface.panel.queryFieldEditor.insertText("fav", replacementRange: NSRange(location: NSNotFound, length: 0))
        draw(card)
        #expect(card.selectedItem?.id == "favorite")
        #expect(cache.misses > misses, "the filter highlights a title, which is a new line")
    }

    @Test func aNewThemeClearsTheLines() {
        let (surface, card) = presentedCard()
        defer { surface.panel.close() }
        #expect(card.list.lineCache.count > 0)
        surface.panel.appearance = NSAppearance(named: .darkAqua)
        surface.refreshTheme()
        #expect(card.list.lineCache.count == 0)
        draw(card)
        #expect(card.list.lineCache.count > 0)
    }

    @Test func turningTheCacheOffKeepsNothing() {
        let (surface, card) = presentedCard()
        defer { surface.panel.close() }
        card.usesLineCache = false
        card.list.lineCache.removeAll()
        draw(card)
        #expect(card.list.lineCache.count == 0)
        #expect(card.list.lineCache.misses == 0)
    }
}
