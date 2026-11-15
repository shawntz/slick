import AppKit

/// What the HUD says.
nonisolated public struct HUDContent: Sendable, Equatable {
    public var text: String
    /// An SF Symbol before the text, such as "checkmark.circle.fill".
    public var symbolName: String?

    public init(_ text: String, symbolName: String? = nil) {
        self.text = text
        self.symbolName = symbolName
    }
}

/// The message that confirms an action after the panel closed: a small glass capsule at the
/// bottom centre of the screen that fades in, stays for the theme's `hudDuration` and fades out.
///
/// It is its own tiny window, never key and never activating, and every click passes through it.
/// Its glass shows the flatter non-key look, so its tint is stronger than the panel's.
public final class HUDWindow: NSPanel {
    /// The theme the HUD draws with.
    public var theme: Theme {
        didSet { if theme != oldValue, let content { layOut(content) } }
    }
    /// Display settings to use instead of the system's, for captures and tests.
    public var accessibilityOverride: DisplayAccessibility?
    /// What the HUD shows now, or nil while hidden.
    public private(set) var content: HUDContent?

    private let root = FlippedView()
    private let glass = NSGlassEffectView()
    private let body = FlippedView()
    private let symbol = NSImageView()
    private let label = FixedLabel()
    /// The label showing the text, for tests.
    var textLabel: NSTextField? { label }
    /// Counts shows, so a hide scheduled by an earlier show does not hide a later one.
    private var generation = 0

    public init(theme: Theme = .standard) {
        self.theme = theme
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Before the level: making a panel floating resets its level to floating.
        isFloatingPanel = true
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        contentView = root
        root.wantsLayer = true
        root.addSubview(glass)
        glass.style = .regular
        glass.contentView = body
        // Frames are set by hand; nothing resizes with the glass.
        body.autoresizesSubviews = false
        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = .labelColor
        label.textColor = .labelColor
        // Left aligned in a frame sized to the text. Centred, this label truncated text that fit.
        label.alignment = .left
        body.addSubview(symbol)
        body.addSubview(label)
        setAccessibilityRole(.window)
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    /// Renders the HUD once while invisible, so the first real show does not pay for the first
    /// glass render. Call once at launch.
    public func prewarm() {
        layOut(HUDContent(" "))
        alphaValue = 0
        orderFrontRegardless()
        displayIfNeeded()
        CATransaction.flush()
        orderOut(nil)
    }

    /// Shows `content` at the bottom centre of `visibleFrame` (default: the main screen's), then
    /// hides it after the theme's duration. A new show replaces one in progress.
    public func show(_ content: HUDContent, on visibleFrame: CGRect? = nil) {
        self.content = content
        generation += 1
        let current = generation
        let resolved = layOut(content)
        let feedback = theme.feedback
        let frame = visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = self.frame.size
        setFrameOrigin(
            CGPoint(
                x: (frame.midX - size.width / 2).rounded(),
                y: frame.minY + CGFloat(feedback.hudBottomMargin - feedback.hudShadowInset)))
        let fade = resolved.motion.hudFade
        alphaValue = fade > 0 ? 0 : 1
        orderFrontRegardless()
        if fade > 0 { animate(to: 1, duration: fade) }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: content.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(feedback.hudDuration + fade))
            self?.hide(ifStill: current)
        }
    }

    /// Hides the HUD now.
    public func hide() {
        generation += 1
        content = nil
        orderOut(nil)
    }

    private func hide(ifStill shown: Int) {
        guard shown == generation else { return }
        let fade = resolvedTheme().motion.hudFade
        guard fade > 0 else { return hide() }
        animate(to: 0, duration: fade)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade))
            guard let self, shown == generation else { return }
            hide()
        }
    }

    private func animate(to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = duration
                animator().alphaValue = alpha
            }, completionHandler: nil)
    }

    private func resolvedTheme() -> ResolvedTheme {
        ResolvedTheme(
            theme: theme, appearance: root.effectiveAppearance, accessibility: accessibilityOverride ?? .current)
    }

    /// Styles and sizes the capsule and the window around it.
    @discardableResult
    private func layOut(_ content: HUDContent) -> ResolvedTheme {
        let resolved = resolvedTheme()
        let feedback = theme.feedback
        let height = CGFloat(feedback.hudHeight)
        let padding = CGFloat(feedback.hudPadding)
        let inset = CGFloat(feedback.hudShadowInset)
        label.font = resolved.feedback.hudFont
        label.stringValue = content.text
        symbol.image = content.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: CGFloat(feedback.hudSymbolSize), weight: .semibold))
        symbol.isHidden = symbol.image == nil
        let symbolWidth = symbol.isHidden ? 0 : CGFloat(feedback.hudSymbolSize) + CGFloat(feedback.hudSymbolGap)
        let textWidth = label.textWidth
        let width = ceil(padding * 2 + symbolWidth + textWidth)
        glass.cornerRadius = height / 2
        glass.tintColor = resolved.feedback.hudTint
        // A never-key glass barely shows its tint, so the same tint also fills the capsule.
        body.wantsLayer = true
        body.layer?.cornerRadius = height / 2
        body.layer?.backgroundColor = resolved.feedback.hudTint?.cgColor
        setContentSize(CGSize(width: width + inset * 2, height: height + inset * 2))
        root.frame = CGRect(x: 0, y: 0, width: width + inset * 2, height: height + inset * 2)
        glass.frame = CGRect(x: inset, y: inset, width: width, height: height)
        body.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if !symbol.isHidden {
            symbol.frame = CGRect(
                x: padding, y: 0, width: CGFloat(feedback.hudSymbolSize), height: height)
        }
        let lineHeight = label.lineHeight
        label.frame = CGRect(
            x: padding + symbolWidth, y: ((height - lineHeight) / 2).rounded(), width: textWidth, height: lineHeight)
        setAccessibilityLabel(content.text)
        return resolved
    }
}
