import AppKit
import QuartzCore

/// A display link that follows a view's screen and calls back once per refresh while running.
///
/// It holds its owner weakly through a proxy target, so an owner can drop it in `deinit`
/// without the retain cycle a display link otherwise makes with its target.
final class DisplayLinkDriver {
    private let proxy: Proxy
    private let link: CADisplayLink

    /// `onTick` receives the link, whose `targetTimestamp` is the refresh being drawn for.
    init(view: NSView, onTick: @escaping (CADisplayLink) -> Void) {
        proxy = Proxy(onTick: onTick)
        link = view.displayLink(target: proxy, selector: #selector(Proxy.tick(_:)))
        link.isPaused = true
        // Common modes keep it ticking while a menu or a drag tracks the mouse.
        link.add(to: .main, forMode: .common)
    }

    var isRunning: Bool {
        get { !link.isPaused }
        set { link.isPaused = !newValue }
    }

    isolated deinit {
        link.invalidate()
    }

    private final class Proxy: NSObject {
        let onTick: (CADisplayLink) -> Void
        init(onTick: @escaping (CADisplayLink) -> Void) { self.onTick = onTick }
        @objc func tick(_ link: CADisplayLink) { onTick(link) }
    }
}
