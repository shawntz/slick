import AppKit
import QuartzCore

/// Animates the glass height from the display link, one frame change per refresh.
///
/// A Core Animation bounds animation would be cheaper, but the glass shape does not follow it:
/// the shape snaps to the final size and is drawn displaced. Driving the frame from the display
/// link held 120 Hz at about 1.4 ms per tick in the lab. Content is laid out at its final size
/// before the animation starts and the glass grows or shrinks over it.
public final class GlassHeightAnimator {
    /// The height applied most recently.
    public private(set) var current: CGFloat
    /// The height the animation ends at.
    public private(set) var target: CGFloat

    private let apply: (CGFloat) -> Void
    private var driver: DisplayLinkDriver?
    private var start: CFTimeInterval = 0
    private var from: CGFloat = 0
    private var duration: CFTimeInterval = 0

    /// `view` provides the display link; `apply` sets the glass height.
    public init(view: NSView, initial: CGFloat, apply: @escaping (CGFloat) -> Void) {
        current = initial
        target = initial
        self.apply = apply
        driver = DisplayLinkDriver(view: view) { [weak self] link in self?.tick(link) }
    }

    public var isAnimating: Bool { driver?.isRunning ?? false }

    /// Animates to `height` over `duration` seconds with an ease-out curve, starting from where
    /// the glass is now, so a new target mid-flight never jumps. A zero duration applies at once.
    public func animate(to height: CGFloat, duration: CFTimeInterval) {
        target = height
        guard duration > 0, height != current else {
            driver?.isRunning = false
            current = height
            apply(height)
            return
        }
        from = current
        start = CACurrentMediaTime()
        self.duration = duration
        driver?.isRunning = true
    }

    private func tick(_ link: CADisplayLink) {
        // targetTimestamp is the refresh being drawn for, so the curve lands on real frames.
        let progress = min(1, max(0, (link.targetTimestamp - start) / duration))
        let eased = 1 - pow(1 - progress, 3)
        current = progress >= 1 ? target : (from + (target - from) * CGFloat(eased)).rounded()
        apply(current)
        if progress >= 1 { driver?.isRunning = false }
    }
}
