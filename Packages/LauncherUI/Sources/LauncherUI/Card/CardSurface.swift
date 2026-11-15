import AppKit

/// The chrome every card and menu shares: a nested glass slab with a stronger tint than the
/// panel's, so it reads as a layer above the content. Subclasses put their views in `body`.
///
/// The card sits in the panel glass's content view, outside any `NSGlassEffectContainerView`,
/// as the lens does: inside a container, nested glass is lifted above the text it holds.
public class CardSurface: NSView {
    /// Where the card's own views go: inside the glass, top-down.
    let body = FlippedView()
    private let glass = NSGlassEffectView()

    override public init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .regular
        glass.contentView = body
        addSubview(glass)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }

    /// Styles the glass. Call from a subclass's `apply(_:)`.
    func applyChrome(_ theme: ResolvedTheme, cornerRadius: Double) {
        glass.cornerRadius = CGFloat(cornerRadius)
        glass.tintColor = theme.card.tint
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = bounds
        body.frame = bounds
        needsLayout = true
    }
}
