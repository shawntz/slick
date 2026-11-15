import AppKit
import QuartzCore

/// A thin indeterminate bar under the query row while something loads.
///
/// A short segment sweeps across, driven by a repeating Core Animation animation that the render
/// server runs: no main-thread timer while it shows. Under Reduce Motion it does not move; a
/// faint full-width bar shows instead.
final class LoadingBarView: NSView {
    private let segment = CALayer()
    private var sweep: Double = 0
    private var fraction: Double = 0.28
    private(set) var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(segment)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: ResolvedTheme) {
        segment.backgroundColor = theme.feedback.loadingBar
        sweep = theme.motion.loadingSweep
        fraction = theme.theme.feedback.loadingSegmentFraction
        if isAnimating { start() }
    }

    override func layout() {
        super.layout()
        if isAnimating { start() }
    }

    /// Shows the bar and starts the sweep.
    func start() {
        isAnimating = true
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        segment.removeAllAnimations()
        let width = bounds.width
        guard sweep > 0 else {
            segment.frame = bounds
            segment.opacity = 0.35
            CATransaction.commit()
            return
        }
        let length = (width * CGFloat(fraction)).rounded()
        segment.opacity = 1
        segment.frame = CGRect(x: -length, y: 0, width: length, height: bounds.height)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -length / 2
        move.toValue = width + length / 2
        move.duration = sweep
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        segment.add(move, forKey: "sweep")
        CATransaction.commit()
    }

    /// Hides the bar and stops the sweep.
    func stop() {
        isAnimating = false
        isHidden = true
        segment.removeAllAnimations()
    }
}
