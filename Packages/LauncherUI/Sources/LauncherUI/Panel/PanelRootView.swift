import AppKit

/// The panel's transparent content view. It hosts the glass and lays out top-down.
///
/// Points outside the glass hit nothing inside the app. The window server already sends clicks
/// there to the window below.
final class PanelRootView: NSView {
    weak var glass: NSView?
    var onEffectiveAppearanceChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    /// Hiding a view from accessibility does not hide its descendants, so a dismissed panel
    /// that stays ordered in would still expose its rows. While hidden it reports none.
    override func accessibilityChildren() -> [Any]? {
        isAccessibilityHidden() ? [] : super.accessibilityChildren()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let glass, glass.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// A top-down view with no drawing of its own.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}
