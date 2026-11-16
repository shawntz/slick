import AppKit
import LauncherUITesting
import Testing

@testable import LauncherUI

/// The split layout: the query row in its own glass and a results container below it, and the
/// clear glass style. Windows stay off every screen and never take key status.
@Suite(.timeLimit(.minutes(1)))
struct SplitPanelTests {
    /// A Beam surface with its query field focused and no animation.
    func makeSurface(content: Bool = true) -> (LauncherSurface, ResultListView) {
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

    @Test func twoPiecesSideBySideWithTheQueryRowInItsOwn() {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        #expect(surface.layout == .split)
        #expect(surface.glassPieces == [surface.glass, surface.resultsGlass])
        // Side by side in the root view, no container, the query row's piece on top.
        #expect(surface.resultsGlass.superview === surface.rootView)
        let order = surface.rootView.subviews
        #expect(order.firstIndex(of: surface.resultsGlass)! < order.firstIndex(of: surface.glass)!)
        #expect(surface.queryField.superview === surface.glass.contentView)
        #expect(surface.lens.view.superview === surface.resultsGlass.contentView)
        #expect(surface.content?.superview === surface.resultsGlass.contentView)
        #expect(surface.actionBar.superview === surface.resultsGlass.contentView)
        #expect(surface.overlaySpace === surface.resultsGlass.contentView)
        #expect(Double(surface.glass.cornerRadius) == 43.5)
        #expect(Double(surface.resultsGlass.cornerRadius) == Theme.beam.panel.cornerRadius)
        #expect(surface.glass.style == .regular && surface.resultsGlass.style == .regular)
    }

    @Test func theResultsContainerHangsBelowTheGapAndHoldsTheActionBar() {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        let field = surface.glass.frame
        let results = surface.resultsGlass.frame
        #expect(field == surface.geometry.fieldFrame)
        #expect(Double(field.height) == Theme.beam.queryRow.height)
        #expect(Double(results.minY - field.maxY) == Theme.beam.panel.fieldGap)
        #expect(results.minX == field.minX && results.width == field.width)
        #expect(results.maxY - field.minY == surface.targetGlassHeight)
        #expect(surface.resultsGlass.alphaValue == 1)
        // Beam shows its action bar only for a toast; GlassPiecesTests covers the toast.
        #expect(surface.actionBar.isHidden)
        // The window holds the tallest stack, gap included.
        let insets = Theme.beam.panel.shadowInsets
        #expect(
            Double(surface.geometry.windowFrame.height) == Theme.beam.maxGlassHeight + insets.top + insets.bottom)
    }

    @Test func noContentHidesTheContainerByOpacityAndTheFieldStaysPut() {
        let (surface, list) = makeSurface()
        defer { surface.panel.close() }
        let field = surface.glass.frame
        surface.setContent(nil, animated: false)
        #expect(surface.targetGlassHeight == 87)
        #expect(surface.resultsGlass.alphaValue == 0)
        // Still in the window and laid out, so it never pays a first render on a keystroke.
        #expect(!surface.resultsGlass.isHidden && surface.resultsGlass.superview === surface.rootView)
        #expect(surface.resultsGlass.frame.height > 0)
        #expect(surface.glass.frame == field)
        surface.setContent(list, animated: false)
        #expect(surface.resultsGlass.alphaValue == 1)
        #expect(surface.glass.frame == field)
    }

    @Test func clicksReachEitherPieceButNotTheGap() throws {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        let root = surface.rootView
        let superview = try #require(root.superview)
        func hit(_ point: CGPoint) -> NSView? { root.hitTest(root.convert(point, to: superview)) }
        let field = surface.glass.frame
        let results = surface.resultsGlass.frame
        #expect(hit(CGPoint(x: field.midX, y: field.midY)) != nil)
        #expect(hit(CGPoint(x: results.midX, y: results.midY)) != nil)
        #expect(hit(CGPoint(x: field.midX, y: field.maxY + 5)) == nil)
        surface.setContent(nil, animated: false)
        #expect(hit(CGPoint(x: results.midX, y: results.minY + 20)) == nil, "a hidden container takes no clicks")
    }

    @Test func aMenuFromAChipInTheQueryRowOpensInTheContainer() throws {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        surface.queryField.filter = QueryFilter(
            options: [MenuOption(id: "a", title: "All"), MenuOption(id: "b", title: "Text")], selectedID: "a",
            label: "Type")
        surface.rootView.layoutSubtreeIfNeeded()
        surface.queryField.openFilterMenu()
        let menu = try #require(surface.overlay)
        #expect(menu.superview === surface.resultsGlass.contentView)
        #expect(menu.frame.minY >= CGFloat(Theme.beam.card.margin) - 0.5)
        #expect(menu.frame.maxY <= surface.resultsGlass.frame.height)
        // A click on the query row's piece closes the menu, as a click outside a menu does.
        #expect(surface.fieldShield.superview === surface.glass.contentView)
        #expect(surface.fieldShield.frame == surface.glass.contentView?.bounds)
        surface.fieldShield.mouseDown(with: NSEvent())
        #expect(surface.overlay == nil)
        #expect(surface.fieldShield.superview == nil && surface.shield.superview == nil)
    }

    @Test func aCardMakesRoomInAHiddenContainer() {
        let (surface, _) = makeSurface(content: false)
        defer { surface.panel.close() }
        #expect(surface.resultsGlass.alphaValue == 0)
        surface.present(
            ConfirmCardView(
                content: ConfirmContent(title: "Delete?", message: "Gone for good.", confirmTitle: "Delete")))
        surface.updateHeight(animated: false)
        #expect(surface.resultsGlass.alphaValue == 1)
        let card = surface.overlay!.frame
        #expect(card.minY >= 0 && card.maxY <= surface.resultsGlass.frame.height)
        surface.dismissOverlay()
    }

    @Test func switchingLayoutsWhileShownKeepsFocusAndMovesTheContentSide() {
        let (surface, list) = makeSurface()
        defer { surface.panel.close() }
        #expect(surface.panel.firstResponder === surface.panel.queryFieldEditor)
        surface.theme = .standard
        #expect(surface.layout == .single)
        #expect(surface.resultsGlass.superview == nil)
        #expect(surface.glassPieces == [surface.glass])
        #expect(surface.lens.view.superview === surface.glass.contentView)
        #expect(list.superview === surface.glass.contentView)
        #expect(list.frame.minY == CGFloat(Theme.standard.queryRow.height))
        #expect(surface.glass.frame.height == surface.targetGlassHeight)
        #expect(Double(surface.glass.cornerRadius) == Theme.standard.panel.cornerRadius)
        #expect(surface.panel.firstResponder === surface.panel.queryFieldEditor)
        // Lens and content stay under the query field in one piece.
        let order = surface.glass.contentView!.subviews
        #expect(order.firstIndex(of: list)! < order.firstIndex(of: surface.queryField)!)
        surface.theme = .beam
        #expect(list.superview === surface.resultsGlass.contentView && list.frame.minY == 0)
        #expect(surface.panel.firstResponder === surface.panel.queryFieldEditor)
    }

    @Test func aCardKeepsFocusWhenTheLayoutChangesUnderIt() throws {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        let card = ActionCardView(
            content: ActionCardContent(sections: [
                ActionSection(items: [ActionItem(id: "a", title: "Open"), ActionItem(id: "b", title: "Copy")])
            ]))
        surface.present(card)
        let focus = surface.panel.firstResponder
        surface.theme = .clear
        #expect(card.superview === surface.glass.contentView)
        #expect(surface.panel.firstResponder === focus)
        surface.dismissOverlay()
    }

    @Test func theLoadingBarRunsAlongTheCapsulesStraightEdge() throws {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        surface.isLoading = true
        let bar = try #require(surface.glass.contentView?.subviews.compactMap { $0 as? LoadingBarView }.first)
        #expect(!bar.isHidden)
        #expect(bar.frame.minX == 43.5 && bar.frame.maxX == 680 - 43.5)
        #expect(bar.frame.maxY == 87)
    }

    @Test func theRootGlyphHidesAndTheTextStartsAtTheInset() {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        surface.rootView.layoutSubtreeIfNeeded()
        let field = surface.queryField
        #expect(field.glyphView.isHidden)
        #expect(abs(field.textField.frame.minX - 36) < 0.01, "the field draws its text 2 pt in")
        field.leading = QueryLeading(glyph: .back, breadcrumb: "Clipboard History")
        field.layoutSubtreeIfNeeded()
        #expect(!field.glyphView.isHidden)
        #expect(field.glyphView.frame.minX == 38)
        #expect(field.textField.frame.minX > field.breadcrumb.frame.maxX)
    }

    @Test func clearGlassHasNoTintAndTurnsRegularUnderReduceTransparency() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.theme = .clear
        #expect(surface.layout == .single)
        #expect(surface.glass.style == .clear)
        #expect(surface.glass.tintColor == nil)
        surface.accessibilityOverride = DisplayAccessibility(reduceTransparency: true)
        #expect(surface.glass.style == .regular && surface.glass.tintColor == nil)
        surface.accessibilityOverride = nil
        surface.theme = .standard
        #expect(surface.glass.style == .regular && surface.glass.tintColor != nil)
    }

    @Test func theShadowAndRimFollowEveryPieceThatShows() throws {
        let (surface, _) = makeSurface()
        defer { surface.panel.close() }
        let decor = surface.rootView.subviews.compactMap { $0 as? GlassDecorView }
        #expect(decor.count == 2)
        #expect(decor.allSatisfy { !$0.isHidden })
        #expect(decor.allSatisfy { $0.hitTest(CGPoint(x: 100, y: 100)) == nil })
        surface.theme = .standard
        #expect(decor.allSatisfy { $0.isHidden }, "Standard draws neither")
    }
}

/// The caret glow, which follows the query field's caret.
@Suite(.timeLimit(.minutes(1)))
struct CaretGlowTests {
    @Test func theGlowSitsOnTheCaretAndHidesWithASelection() throws {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.theme = .beam
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        surface.rootView.layoutSubtreeIfNeeded()
        let field = surface.queryField
        let glow = field.caretGlow
        #expect(glow.hasGlow)
        #expect(!glow.isHidden)
        let empty = glow.frame.midX
        #expect(abs(empty - field.textField.frame.minX - 2) < 2, "at the start of the text")
        #expect(abs(glow.frame.midY - field.textField.frame.midY) < 0.5)
        field.text = "launch"
        let typed = glow.frame.midX
        #expect(typed > empty + 30)
        let editor = try #require(field.textField.currentEditor())
        editor.selectedRange = NSRange(location: 0, length: 3)
        #expect(glow.isHidden)
        editor.selectedRange = NSRange(location: 6, length: 0)
        #expect(!glow.isHidden && glow.frame.midX == typed)
    }

    @Test func aThemeWithoutAGlowDrawsNone() {
        let surface = TestSupport.makeSurface()
        defer { surface.panel.close() }
        surface.panel.orderFrontRegardless()
        surface.queryField.installEditor()
        surface.queryField.text = "x"
        #expect(!surface.queryField.caretGlow.hasGlow && surface.queryField.caretGlow.isHidden)
        #expect(surface.panel.queryFieldEditor.insertionPointColor == NSColor(cgColor: surface.resolvedTheme.accent))
    }

    @Test func theImageIsBrightestBesideTheCaretAndColouredTopToBottom() throws {
        let colors = [
            CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        ]
        let image = try #require(
            CaretGlowView.image(colors: colors, caret: CGSize(width: 2, height: 26), reach: 18, scale: 1))
        #expect(image.width == 38 && image.height == 62)
        let data = try #require(image.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(data[(y * image.width + x) * 4..<(y * image.width + x) * 4 + 4])
        }
        let top = pixel(19, 18)
        let bottom = pixel(19, 43)
        #expect(top[2] > top[0], "blue at the top")
        #expect(bottom[0] > bottom[2], "red at the bottom")
        #expect(pixel(19, 30)[3] > pixel(30, 30)[3])
        #expect(pixel(0, 0)[3] < 10)
    }
}
