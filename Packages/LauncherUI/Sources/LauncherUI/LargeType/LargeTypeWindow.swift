import AppKit

/// Large Type: a text in very large letters across the screen with the pointer, to read a phone
/// number or a code from across the room.
///
/// A borderless panel the size of its dark rounded backing, centered on the screen. It never
/// activates the app, but it takes key status, so the next key reaches it. Any key, any click on
/// it, and the window losing key status hide it; a click elsewhere goes to another app, which
/// takes key status. ``LargeTypeDismissal`` holds those rules. Show it after the launcher panel
/// has closed.
public final class LargeTypeWindow: NSPanel {
    /// The theme the backing follows.
    public var theme: Theme
    /// Display settings to use instead of the system's, for tests.
    public var accessibilityOverride: DisplayAccessibility?
    /// What shows now, or showed last.
    public private(set) var layout: LargeTypeLayout?
    /// When to hide.
    public let dismissal = LargeTypeDismissal()
    /// Runs after it hid, whatever hid it.
    public var onHide: (() -> Void)?

    private let backing = LargeTypeView()
    private var appObserver: (any NSObjectProtocol)?

    public init(theme: Theme = .standard) {
        self.theme = theme
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Before the level: making a panel floating resets its level to floating.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        contentView = backing
        setAccessibilityRole(.window)
        dismissal.onDismiss = { [weak self] in self?.hideNow() }
        appObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.dismissal.handle(.appResignedActive) }
        }
    }

    isolated deinit {
        if let appObserver { NotificationCenter.default.removeObserver(appObserver) }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// The screen under the pointer, where Large Type shows.
    public static var pointerScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// Shows `text` centered on `visibleFrame`, by default the visible frame of the screen with the
    /// pointer, and takes key status. A text showing already is replaced.
    public func show(_ text: String, on visibleFrame: CGRect? = nil) {
        let screen = visibleFrame ?? Self.pointerScreen?.visibleFrame ?? .zero
        let style = LargeTypeStyle(theme: theme, accessibility: accessibilityOverride ?? .current)
        let layout = LargeTypeLayout.make(text, screen: screen, font: style.font)
        self.layout = layout
        dismissal.reset()
        backing.apply(layout, style: style)
        setFrame(layout.frame, display: true)
        orderFrontRegardless()
        makeKey()
        dismissal.shown()
        setAccessibilityLabel(layout.text)
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: layout.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Hides it now.
    public func hide() {
        guard dismissal.isShown else { return }
        dismissal.reset()
        hideNow()
    }

    private func hideNow() {
        orderOut(nil)
        onHide?()
    }

    // MARK: Events

    override public func keyDown(with event: NSEvent) {
        dismissal.handle(.keyDown(isRepeat: event.isARepeat))
    }

    /// Command chords come here first. While Large Type shows, any of them hides it and goes no
    /// further; a held chord's repeats are swallowed.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, dismissal.isShown else { return super.performKeyEquivalent(with: event) }
        dismissal.handle(.keyDown(isRepeat: event.isARepeat))
        return true
    }

    override public func cancelOperation(_ sender: Any?) {
        dismissal.handle(.keyDown(isRepeat: false))
    }

    override public func mouseDown(with event: NSEvent) {
        dismissal.handle(.click)
    }

    override public func rightMouseDown(with event: NSEvent) {
        dismissal.handle(.click)
    }

    override public func otherMouseDown(with event: NSEvent) {
        dismissal.handle(.click)
    }

    override public func resignKey() {
        super.resignKey()
        dismissal.handle(.resignedKey)
    }
}

/// The dark rounded backing and the text on it.
final class LargeTypeView: NSView {
    private(set) var layout: LargeTypeLayout?
    private(set) var style: LargeTypeStyle?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ layout: LargeTypeLayout, style: LargeTypeStyle) {
        self.layout = layout
        self.style = style
        wantsLayer = true
        layer?.backgroundColor = style.fill
        layer?.cornerRadius = style.cornerRadius
        layer?.cornerCurve = .continuous
        frame = CGRect(origin: .zero, size: layout.frame.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let style else { return }
        let color = NSColor(cgColor: style.text) ?? .white
        let text = LargeTypeLayout.attributed(layout.text, font: style.font, size: layout.fontSize, color: color)
        var options = LargeTypeLayout.drawingOptions
        if layout.isCut { options.insert(.truncatesLastVisibleLine) }
        text.draw(with: layout.textFrame, options: options, context: nil)
    }

    // A click on the text goes to the window, which hides Large Type.
    override func mouseDown(with event: NSEvent) {
        window?.mouseDown(with: event)
    }
}
