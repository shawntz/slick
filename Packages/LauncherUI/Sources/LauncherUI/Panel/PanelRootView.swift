import AppKit

/// The panel's transparent content view. It hosts the glass and lays out top-down.
///
/// Points outside every piece of glass, the gap between split pieces included, hit nothing inside
/// the app. The window server already sends clicks there to the window below.
final class PanelRootView: NSView {
    /// The pieces of glass that take clicks while they show.
    var pieces: [NSView] = []
    var onEffectiveAppearanceChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    /// Hiding a view from accessibility does not hide its descendants, so a dismissed panel
    /// that stays ordered in would still expose its rows. While hidden it reports none.
    ///
    /// The query row's piece comes first, as people read the panel, even where it sits above the
    /// results container in the view order so that its shadow falls the right way.
    override func accessibilityChildren() -> [Any]? {
        guard !isAccessibilityHidden() else { return [] }
        guard let children = super.accessibilityChildren(), let first = pieces.first, pieces.count > 1 else {
            return super.accessibilityChildren()
        }
        // A child is a view, a control's cell, such as the search field's, or an element a view made.
        func inFirstPiece(_ child: Any) -> Bool {
            let view =
                (child as? NSView) ?? (child as? NSCell)?.controlView
                ?? ((child as? NSAccessibilityElement)?.accessibilityParent() as? NSView)
            return view.map { $0 === first || $0.isDescendant(of: first) } ?? false
        }
        return children.filter(inFirstPiece) + children.filter { !inFirstPiece($0) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard pieces.contains(where: { !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(local) }) else {
            return nil
        }
        return super.hitTest(point)
    }
}

/// A top-down view with no drawing of its own.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}
