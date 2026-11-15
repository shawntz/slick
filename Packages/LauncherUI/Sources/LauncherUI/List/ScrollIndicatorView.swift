import AppKit

/// A thin capsule at the trailing edge that shows where the list is scrolled. It appears only
/// while the list scrolls and fades out shortly after.
final class ScrollIndicatorView: NSView {
    private var metrics = Theme.standard.list
    private var fade: Double = 0
    private var hideTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: ResolvedTheme) {
        metrics = theme.theme.list
        fade = theme.motion.scrollIndicatorFade
        layer?.backgroundColor = theme.scrollIndicator
        layer?.cornerRadius = CGFloat(metrics.scrollIndicatorWidth) / 2
    }

    /// Sizes and places the capsule for a scroll position. Hides it when nothing scrolls.
    func update(offset: CGFloat, content: Double, viewport: CGFloat) {
        guard let superview, content > Double(viewport), viewport > 0 else {
            isHidden = true
            return
        }
        let inset = CGFloat(metrics.scrollIndicatorInset)
        let track = viewport - inset * 2
        let length = max(CGFloat(metrics.scrollIndicatorWidth) * 8, track * viewport / CGFloat(content))
        let progress = offset / (CGFloat(content) - viewport)
        let width = CGFloat(metrics.scrollIndicatorWidth)
        frame = CGRect(
            x: superview.bounds.width - inset - width, y: inset + (track - length) * min(max(progress, 0), 1),
            width: width, height: length
        )
    }

    /// Shows the capsule now and fades it out after the theme's linger time.
    func flash() {
        guard frame.height > 0 else { return }
        isHidden = false
        alphaValue = 1
        hideTask?.cancel()
        let linger = metrics.scrollIndicatorLinger
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = self.fade
                    self.animator().alphaValue = 0
                }, completionHandler: nil)
        }
    }
}
