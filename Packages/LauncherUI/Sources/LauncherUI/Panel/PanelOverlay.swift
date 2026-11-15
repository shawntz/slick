import AppKit

/// Where an overlay sits inside the glass.
public enum OverlayPlacement: Equatable {
    /// The bottom-right corner, above the action bar: the action card.
    case bottomTrailing
    /// The middle of the content area: the confirm card.
    case center
    /// Just under a rectangle in the glass content's coordinates, aligned with its leading or
    /// trailing edge, or just above it when there is no room below: dropdown menus.
    case below(CGRect, trailingAligned: Bool)
}

/// A card or menu drawn over the content, inside the panel.
///
/// The glass shows its full look only while the panel is key, so anything that would otherwise be
/// a popover, a sheet or a menu window is an overlay instead. `LauncherSurface.present(_:)` adds
/// it above everything in the glass, gives it keyboard focus, dims what is behind it when it asks,
/// and grows the glass when the content is too short to hold it.
public protocol PanelOverlay: NSView {
    var placement: OverlayPlacement { get }
    /// Whether the content, the query row and the lens dim while the overlay shows.
    var dimsBehind: Bool { get }
    /// The size the overlay wants, at most `maximum`.
    func overlaySize(maximum: CGSize) -> CGSize
    func apply(_ theme: ResolvedTheme)
    /// The view that takes keyboard focus while the overlay shows.
    var focusView: NSView? { get }
    /// Set by the surface. Call it when `overlaySize(maximum:)` changes.
    var overlaySizeDidChange: (() -> Void)? { get set }
    /// Called after the surface removed the overlay, whatever the reason.
    func overlayDidDismiss()
    /// Called after the overlay is placed and before its focus view takes the keyboard. Size any
    /// text field here: resizing a field while it is edited ends its editing. Do it by hand, not
    /// with `layoutSubtreeIfNeeded()`, which runs the window's layout engine (1 to 2 ms).
    func prepareToShow()
}

extension PanelOverlay {
    public func prepareToShow() {}

    /// Asks the panel's surface to remove this overlay, if it is the one showing.
    func dismissFromPanel() {
        guard let surface = (window as? GlassPanel)?.surface, surface.overlay === self else { return }
        surface.dismissOverlay()
    }
}

/// Covers the glass under an overlay. A click on it dismisses the overlay instead of reaching the
/// content, as a click outside a menu closes it.
final class OverlayShield: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func scrollWheel(with event: NSEvent) {}
}
