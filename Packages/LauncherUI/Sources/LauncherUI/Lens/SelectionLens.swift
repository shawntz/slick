import AppKit
import QuartzCore

/// The highlight behind the selected row or tile.
///
/// Its `view` must be a direct subview of the panel glass's content view, below the content.
/// Inside an `NSGlassEffectContainerView` the lens glass would be lifted above the text and its
/// position animations ignored. It moves by a Core Animation position spring, which the render
/// server runs: one main-thread call per move. Size changes are applied at once, never animated,
/// because the glass shape does not follow a bounds animation.
public final class SelectionLens {
    /// The view to insert into the glass content view. It is replaced when the style changes,
    /// so read it again after `apply(_:)`.
    public private(set) var view: NSView
    public private(set) var style: LensMetrics.Style
    /// Called after `apply(_:)` replaced `view`, so the owner can insert the new one.
    public var onViewReplaced: ((_ old: NSView, _ new: NSView) -> Void)?

    /// The corner radius for the current content, or nil for the theme's. A grid sets its own
    /// smaller radius; `LauncherSurface` clears it whenever the content changes.
    public var cornerRadius: CGFloat? {
        didSet { if cornerRadius != oldValue { applyCornerRadius() } }
    }

    private var glideDuration: Double = 0
    private var themeRadius: CGFloat = 0

    public init(style: LensMetrics.Style = .glass) {
        self.style = style
        view = Self.makeView(style)
        view.isHidden = true
    }

    /// Whether the lens is shown.
    public var isHidden: Bool {
        get { view.isHidden }
        set { view.isHidden = newValue }
    }

    /// Restyles the lens, rebuilding its view when the style changed.
    public func apply(_ theme: ResolvedTheme) {
        let metrics = theme.theme.lens
        if metrics.style != style {
            let old = view
            style = metrics.style
            view = Self.makeView(style)
            view.frame = old.frame
            view.isHidden = old.isHidden
            onViewReplaced?(old, view)
        }
        glideDuration = theme.motion.lensGlide
        themeRadius = CGFloat(metrics.cornerRadius)
        switch view {
        case let glass as NSGlassEffectView:
            glass.tintColor = theme.lensGlassTint
        default:
            view.layer?.backgroundColor = theme.lensFill
        }
        applyCornerRadius()
    }

    private func applyCornerRadius() {
        let radius = cornerRadius ?? themeRadius
        switch view {
        case let glass as NSGlassEffectView: glass.cornerRadius = radius
        default: view.layer?.cornerRadius = radius
        }
    }

    /// Moves the lens to `frame`, in its superview's coordinates. A move that keeps the size
    /// glides when `animated`; anything else jumps.
    public func move(to frame: CGRect, animated: Bool) {
        guard let layer = view.layer else {
            view.frame = frame
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        let glides =
            animated && glideDuration > 0 && !view.isHidden && view.frame.size == frame.size
            && view.frame.origin != frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.glideKey)
        view.frame = frame
        CATransaction.commit()
        guard glides else { return }
        // Critically damped: no bounce, settles in about the perceptual duration.
        let spring = CASpringAnimation(perceptualDuration: glideDuration, bounce: 0)
        spring.keyPath = "position"
        spring.fromValue = NSValue(point: from)
        spring.toValue = NSValue(point: layer.position)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: Self.glideKey)
    }

    private static let glideKey = "glide"

    private static func makeView(_ style: LensMetrics.Style) -> NSView {
        let view: NSView
        switch style {
        case .glass:
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = NSView()
            view = glass
        case .fill:
            view = NSView()
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
        }
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        return view
    }
}
