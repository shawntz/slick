import AppKit

/// The launcher window and everything in it: the panel, one glass slab, the query row, a hairline,
/// the content area and the action bar.
///
/// Hosts fill the query field, the action bar and the content; the surface keeps them laid out,
/// sizes the glass to the content, follows light and dark mode and the accessibility display
/// settings, and moves the window to the screen with the pointer.
///
/// Inside the glass, top-down: the query row, the hairline when content follows, the content and
/// the action bar. The selection lens sits under the content, directly in the glass content view.
public final class LauncherSurface {
    public let panel: GlassPanel
    public let queryField = QueryField()
    public let actionBar = ActionBar()
    public let lens: SelectionLens
    /// The panel's content view. `Summoner` shows and hides the panel through its layer.
    public var rootView: NSView { root }
    /// The glass slab.
    public let glass = NSGlassEffectView()
    public private(set) var content: (any LauncherContentView)?
    /// The card or menu shown over the content, if any. See `present(_:)`.
    public internal(set) var overlay: (any PanelOverlay)?
    public private(set) var geometry: PanelGeometry
    public private(set) var resolvedTheme: ResolvedTheme

    public var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            let geometry = PanelGeometry(theme: theme, visibleFrame: currentVisibleFrame)
            // Only a change of size or placement metrics moves the window; colours and styles do not.
            if geometry != self.geometry {
                self.geometry = geometry
                panel.setFrame(geometry.windowFrame, display: false)
                root.frame = CGRect(origin: .zero, size: geometry.windowFrame.size)
            }
            refreshTheme()
        }
    }

    /// Display settings to use instead of the system's, for captures and tests.
    public var accessibilityOverride: DisplayAccessibility? {
        didSet { if accessibilityOverride != oldValue { refreshTheme() } }
    }

    private let root = PanelRootView()
    let glassContent = FlippedView()
    private let hairline = NSView()
    private let loadingBar = LoadingBarView()
    let shield = OverlayShield()
    /// The last dismissed overlay, hidden in the glass for a cheap next present.
    var parkedOverlay: (any PanelOverlay)?
    /// The theme the parked overlay was last styled with, so presenting it again skips restyling.
    var parkedOverlayTheme: ResolvedTheme?
    /// Who had keyboard focus before the overlay took it.
    weak var focusBeforeOverlay: NSResponder?
    private var heightAnimator: GlassHeightAnimator?
    private var accessibilityObserver: DisplayAccessibilityObserver?
    private var currentVisibleFrame: CGRect

    /// Builds the window on `visibleFrame`, by default the main screen's.
    public init(theme: Theme = .standard, visibleFrame: CGRect? = nil) {
        let frame = visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        currentVisibleFrame = frame
        self.theme = theme
        geometry = PanelGeometry(theme: theme, visibleFrame: frame)
        panel = GlassPanel(contentRect: geometry.windowFrame)
        lens = SelectionLens(style: theme.lens.style)
        resolvedTheme = ResolvedTheme(theme: theme, appearance: NSAppearance.currentDrawing(), accessibility: .current)

        root.frame = CGRect(origin: .zero, size: geometry.windowFrame.size)
        root.wantsLayer = true
        panel.contentView = root
        root.glass = glass
        root.addSubview(glass)
        glass.style = .regular
        glass.contentView = glassContent
        glass.frame = geometry.glassFrame(height: theme.glassHeight(contentHeight: 0))

        hairline.wantsLayer = true
        hairline.isHidden = true
        actionBar.isHidden = true
        loadingBar.isHidden = true
        for view in [lens.view, queryField, hairline, loadingBar, actionBar] { glassContent.addSubview(view) }
        panel.surface = self
        shield.onClick = { [weak self] in self?.dismissOverlay() }
        lens.onViewReplaced = { [weak self] old, new in
            self?.glassContent.addSubview(new, positioned: .below, relativeTo: old)
            old.removeFromSuperview()
        }
        panel.onKeyEquivalent = { [weak self] event in self?.queryField.handleKeyEquivalent(event) ?? false }

        heightAnimator = GlassHeightAnimator(view: root, initial: glass.frame.height) { [weak self] height in
            self?.applyGlassHeight(height)
        }
        root.onEffectiveAppearanceChange = { [weak self] in self?.refreshTheme() }
        accessibilityObserver = DisplayAccessibilityObserver { [weak self] _ in self?.refreshTheme() }
        refreshTheme()
    }

    // MARK: Content

    /// Shows `view` in the content area, or nothing. The glass follows its height.
    public func setContent(_ view: (any LauncherContentView)?, animated: Bool) {
        guard view !== content else { return }
        if let content {
            content.selectionLens = nil
            content.contentHeightDidChange = nil
            content.removeFromSuperview()
        }
        content = view
        lens.isHidden = true
        lens.cornerRadius = nil
        if let view {
            view.frame = CGRect(
                x: 0, y: theme.queryRow.height, width: theme.panel.width, height: theme.panel.maxContentHeight)
            glassContent.addSubview(view, positioned: .above, relativeTo: lens.view)
            view.apply(resolvedTheme)
            view.selectionLens = lens
            view.contentHeightDidChange = { [weak self] in self?.updateHeight(animated: true) }
        }
        updateHeight(animated: animated)
    }

    /// The content height the glass is sized for now: the content's, or more while an overlay
    /// needs the room.
    public var contentHeight: CGFloat {
        let limit = CGFloat(theme.panel.maxContentHeight)
        let wanted = content?.preferredContentHeight(limit: limit) ?? 0
        return min(limit, max(wanted, overlayRequiredHeight))
    }

    /// The glass height the current content asks for.
    public var targetGlassHeight: CGFloat { CGFloat(theme.glassHeight(contentHeight: Double(contentHeight))) }

    /// The glass height shown now, mid-animation included.
    var currentGlassHeight: CGFloat { heightAnimator?.current ?? glass.frame.height }

    /// Whether the glass height is animating now.
    public var isAnimatingHeight: Bool { heightAnimator?.isAnimating ?? false }

    /// Sizes the glass to the content. Content is already laid out at its final size; when
    /// `animated` the glass grows or shrinks over it from the display link.
    public func updateHeight(animated: Bool) {
        let height = contentHeight
        let showsContent = height > 0
        hairline.isHidden = !showsContent
        actionBar.isHidden = !showsContent
        heightAnimator?.animate(to: targetGlassHeight, duration: animated ? resolvedTheme.motion.heightChange : 0)
    }

    // MARK: Loading

    /// Shows the thin indeterminate bar under the query row while true.
    public var isLoading: Bool = false {
        didSet {
            guard isLoading != oldValue else { return }
            if isLoading { loadingBar.start() } else { loadingBar.stop() }
        }
    }

    // MARK: Placement

    /// The screen that holds the pointer, or the main screen.
    public static func screenWithPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    /// Places the window on a visible frame (a screen's `visibleFrame`).
    public func place(visibleFrame: CGRect) {
        currentVisibleFrame = visibleFrame
        let geometry = PanelGeometry(theme: theme, visibleFrame: visibleFrame)
        guard geometry != self.geometry || panel.frame != geometry.windowFrame else { return }
        self.geometry = geometry
        panel.setFrame(geometry.windowFrame, display: false)
    }

    /// Puts the window's bottom-left corner at `origin`, outside the usual placement. For
    /// captures and benchmarks that keep the panel out of the way.
    public func place(windowOrigin origin: CGPoint) {
        panel.setFrameOrigin(origin)
    }

    /// Moves the window to the screen with the pointer when it is on another one. Returns
    /// whether it moved. The common case, no move, reads two cached values.
    @discardableResult
    public func followPointerScreen() -> Bool {
        guard let screen = Self.screenWithPointer() else { return false }
        let visible = screen.visibleFrame
        guard visible != currentVisibleFrame else { return false }
        place(visibleFrame: visible)
        return true
    }

    // MARK: Theme

    /// Re-resolves the theme for the current appearance and settings and restyles every part.
    public func refreshTheme() {
        let accessibility = accessibilityOverride ?? .current
        resolvedTheme = ResolvedTheme(theme: theme, appearance: root.effectiveAppearance, accessibility: accessibility)
        let resolved = resolvedTheme
        glass.cornerRadius = CGFloat(theme.panel.cornerRadius)
        glass.tintColor = resolved.glassTint
        hairline.layer?.backgroundColor = resolved.hairline
        // One field editor serves the query field, the card filter, chips and form fields.
        panel.queryFieldEditor.insertionPointColor = NSColor(cgColor: resolved.accent) ?? .controlAccentColor
        queryField.apply(resolved)
        actionBar.apply(resolved)
        lens.apply(resolved)
        loadingBar.apply(resolved)
        content?.apply(resolved)
        overlay?.apply(resolved)
        parkedOverlayTheme = nil
        layoutFixedParts()
        applyGlassHeight(heightAnimator?.current ?? glass.frame.height)
    }

    private func layoutFixedParts() {
        let width = CGFloat(theme.panel.width)
        let queryHeight = CGFloat(theme.queryRow.height)
        queryField.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        let scale = panel.backingScaleFactor
        let hairlineHeight = CGFloat(theme.panel.hairlinePixels) / scale
        hairline.frame = CGRect(x: 0, y: queryHeight - hairlineHeight, width: width, height: hairlineHeight)
        let barHeight = CGFloat(theme.feedback.loadingBarHeight)
        loadingBar.frame = CGRect(x: 0, y: queryHeight - barHeight, width: width, height: barHeight)
        content?.frame = CGRect(x: 0, y: queryHeight, width: width, height: theme.panel.maxContentHeight)
    }

    private func applyGlassHeight(_ height: CGFloat) {
        glass.frame = geometry.glassFrame(height: Double(height))
        // The bar rides the bottom edge of the glass while it animates.
        let barHeight = CGFloat(theme.actionBar.height)
        actionBar.frame = CGRect(x: 0, y: height - barHeight, width: CGFloat(theme.panel.width), height: barHeight)
        guard overlay != nil else { return }
        shield.frame = CGRect(x: 0, y: 0, width: CGFloat(theme.panel.width), height: height)
        layoutOverlay(glassHeight: height)
    }
}
