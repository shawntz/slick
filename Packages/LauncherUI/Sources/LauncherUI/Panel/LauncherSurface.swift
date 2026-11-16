import AppKit

/// The launcher window and everything in it: the panel, its glass, the query row, a hairline, the
/// content area and the action bar.
///
/// Hosts fill the query field, the action bar and the content; the surface keeps them laid out,
/// sizes the glass to the content, follows light and dark mode and the accessibility display
/// settings, and moves the window to the screen with the pointer.
///
/// The theme's `panel.layout` arranges the glass:
/// - Single: one slab. Inside it, top-down: the query row, the hairline when content follows, the
///   content and the action bar. The selection lens sits under the content, directly in the glass
///   content view.
/// - Split: the query row in its own piece of glass, and `fieldGap` below it a results container
///   with the lens, the content, the action bar and any card or menu. The container shows only
///   while there is content, and it grows downward while the query row stays put.
///
/// Either way `targetGlassHeight` and `geometry.glassFrame` describe the whole stack, from the top
/// of the query row to the bottom of the action bar.
public final class LauncherSurface {
    public let panel: GlassPanel
    public let queryField = QueryField()
    public let actionBar = ActionBar()
    public let lens: SelectionLens
    /// The panel's content view. `Summoner` shows and hides the panel through its layer.
    public var rootView: NSView { root }
    /// The glass that holds the query row: the whole slab in the single layout, the query row's own
    /// piece in the split layout.
    public let glass = NSGlassEffectView()
    /// The results container of the split layout. Outside the window in the single layout.
    public let resultsGlass = NSGlassEffectView()
    public private(set) var content: (any LauncherContentView)?
    /// The card or menu shown over the content, if any. See `present(_:)`.
    public internal(set) var overlay: (any PanelOverlay)?
    public private(set) var geometry: PanelGeometry
    public private(set) var resolvedTheme: ResolvedTheme
    /// How the glass is arranged now. It follows the theme.
    public private(set) var layout: PanelLayout = .single
    /// Called after a theme change added, rearranged or restyled a piece of glass, so whoever
    /// shows the panel can render the new glass once while the panel is invisible.
    var onGlassRestyled: (() -> Void)?

    public var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            let geometry = PanelGeometry(theme: theme, visibleFrame: currentVisibleFrame)
            // Only a change of size or placement metrics moves the window; colours and styles do not.
            if geometry != self.geometry {
                self.geometry = geometry
                panel.setFrame(geometry.windowFrame, display: false)
                root.frame = CGRect(origin: .zero, size: geometry.windowFrame.size)
                for decor in [shadowDecor, rimDecor] as [NSView] { decor.frame = root.bounds }
            }
            refreshTheme()
        }
    }

    /// Display settings to use instead of the system's, for captures and tests.
    public var accessibilityOverride: DisplayAccessibility? {
        didSet { if accessibilityOverride != oldValue { refreshTheme() } }
    }

    /// Every piece of glass in the window, the query row's first.
    public var glassPieces: [NSGlassEffectView] { layout == .split ? [glass, resultsGlass] : [glass] }

    /// The view that holds the content, the lens, the action bar and overlays: the glass's content
    /// view in the single layout and the results container's in the split layout. Overlay
    /// placements, such as a menu's anchor, are in its coordinates.
    public var overlaySpace: NSView { contentHost }

    private let root = PanelRootView()
    let glassContent = FlippedView()
    let resultsContent = FlippedView()
    private let hairline = NSView()
    private let loadingBar = LoadingBarView()
    private let fieldShade = FieldShadeView()
    private let shadowDecor = GlassShadowView()
    private let rimDecor = GlassRimView()
    let shield = OverlayShield()
    /// Covers the query row's piece while an overlay shows in the split layout, so a click there
    /// dismisses the overlay as it does in one piece.
    let fieldShield = OverlayShield()
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
        for decor in [shadowDecor, rimDecor] as [NSView] { decor.frame = root.bounds }
        // Bottom to top: the shadow, the glass, then the rim over the glass's edge.
        root.addSubview(shadowDecor)
        root.addSubview(glass)
        root.addSubview(rimDecor)
        glass.style = .regular
        glass.contentView = glassContent
        glass.frame = geometry.glassFrame(height: theme.glassHeight(contentHeight: 0))
        resultsGlass.style = .regular
        resultsGlass.contentView = resultsContent
        resultsGlass.alphaValue = 0

        hairline.wantsLayer = true
        hairline.isHidden = true
        actionBar.isHidden = true
        loadingBar.isHidden = true
        for view in [fieldShade, lens.view, queryField, hairline, loadingBar, actionBar] {
            glassContent.addSubview(view)
        }
        root.pieces = glassPieces
        panel.surface = self
        shield.onClick = { [weak self] in self?.dismissOverlay() }
        actionBar.onToastChange = { [weak self] in
            guard let self, self.theme.actionBar.showsOnlyForToasts else { return }
            updateHeight(animated: true)
        }
        fieldShield.onClick = { [weak self] in self?.dismissOverlay() }
        lens.onViewReplaced = { old, new in
            old.superview?.addSubview(new, positioned: .below, relativeTo: old)
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

    /// Where the content side lives in the current layout.
    var contentHost: FlippedView { layout == .split ? resultsContent : glassContent }

    /// The top of the content area in `contentHost`: under the query row in one piece, the top of
    /// the results container when split.
    var contentTop: CGFloat { layout == .split ? 0 : CGFloat(theme.queryRow.height) }

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
                x: 0, y: contentTop, width: CGFloat(theme.panel.width), height: CGFloat(theme.panel.maxContentHeight))
            contentHost.addSubview(view, positioned: .above, relativeTo: lens.view)
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

    /// The glass height the current content asks for: the whole stack in the split layout.
    public var targetGlassHeight: CGFloat {
        CGFloat(theme.glassHeight(contentHeight: Double(contentHeight), showsToast: actionBar.toast != nil))
    }

    /// The room the action bar takes at the bottom of the content side now.
    var actionBarRoom: CGFloat { CGFloat(theme.actionBarHeight(showsToast: actionBar.toast != nil)) }

    /// The glass height shown now, mid-animation included.
    var currentGlassHeight: CGFloat { heightAnimator?.current ?? glass.frame.height }

    /// The height of the piece that holds the content, shown now: the slab, or the results
    /// container, which is zero while it hides.
    var currentHostHeight: CGFloat { hostHeight(forGlassHeight: currentGlassHeight) }

    private func hostHeight(forGlassHeight height: CGFloat) -> CGFloat {
        guard layout == .split else { return height }
        return max(0, height - CGFloat(theme.queryRow.height + theme.panel.fieldGap))
    }

    /// Whether the glass height is animating now.
    public var isAnimatingHeight: Bool { heightAnimator?.isAnimating ?? false }

    /// Sizes the glass to the content. Content is already laid out at its final size; when
    /// `animated` the glass grows or shrinks over it from the display link.
    public func updateHeight(animated: Bool) {
        let height = contentHeight
        let showsContent = height > 0
        hairline.isHidden = !showsContent || layout == .split
        actionBar.isHidden = !showsContent || actionBarRoom == 0
        heightAnimator?.animate(to: targetGlassHeight, duration: animated ? resolvedTheme.motion.heightChange : 0)
    }

    // MARK: Loading

    /// Shows the thin indeterminate bar under the query row while true. In the split layout it
    /// runs along the straight part of the query row piece's bottom edge.
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
        let rearranged = arrange(theme.panel.layout)
        let split = layout == .split
        var restyled = rearranged
        for piece in [glass, resultsGlass] where piece.style != resolved.glassStyle {
            piece.style = resolved.glassStyle
            restyled = true
        }
        glass.cornerRadius = CGFloat(split ? theme.fieldCornerRadius : theme.panel.cornerRadius)
        glass.tintColor = split ? resolved.fieldTint : resolved.glassTint
        resultsGlass.cornerRadius = CGFloat(theme.panel.cornerRadius)
        resultsGlass.tintColor = resolved.glassTint
        fieldShade.apply(color: split ? resolved.fieldShade : nil, cornerRadius: CGFloat(theme.fieldCornerRadius))
        shadowDecor.apply(
            color: resolved.shadow, radius: CGFloat(theme.panel.shadowRadius), offset: CGFloat(theme.panel.shadowOffset)
        )
        rimDecor.apply(color: resolved.rim, width: CGFloat(theme.panel.rimWidth))
        hairline.layer?.backgroundColor = resolved.hairline
        // One field editor serves the query field, the card filter, chips and form fields.
        panel.queryFieldEditor.insertionPointColor = NSColor(cgColor: resolved.caret) ?? .controlAccentColor
        queryField.apply(resolved)
        actionBar.apply(resolved)
        lens.apply(resolved)
        loadingBar.apply(resolved)
        content?.apply(resolved)
        overlay?.apply(resolved)
        parkedOverlayTheme = nil
        layoutFixedParts()
        // A new layout adds or removes the gap, so the stack takes its new height at once.
        if rearranged { updateHeight(animated: false) } else { applyGlassHeight(currentGlassHeight) }
        if restyled { onGlassRestyled?() }
    }

    /// Runs `body` with every piece of glass laid out and at full opacity, then hides again the
    /// pieces that were hidden. A piece at zero opacity is never rendered, so the summoner renders
    /// the invisible panel this way, and no piece pays its first render on a keystroke.
    func withEveryPieceShown(_ body: () -> Void) {
        let hidden = glassPieces.filter { $0.alphaValue < 1 }
        for piece in hidden { piece.alphaValue = 1 }
        for piece in glassPieces { piece.layoutSubtreeIfNeeded() }
        body()
        for piece in hidden { piece.alphaValue = 0 }
    }

    /// Moves the content side between the slab and the results container when the layout
    /// changes, keeping whatever had keyboard focus. Nothing moves when the layout stays. Returns
    /// whether anything moved.
    @discardableResult
    private func arrange(_ newLayout: PanelLayout) -> Bool {
        guard newLayout != layout else { return false }
        let focus = currentFocus
        layout = newLayout
        let host = contentHost
        if newLayout == .split {
            root.addSubview(resultsGlass, positioned: .below, relativeTo: glass)
            host.addSubview(lens.view)
        } else {
            host.addSubview(lens.view, positioned: .below, relativeTo: queryField)
        }
        if let content { host.addSubview(content, positioned: .above, relativeTo: lens.view) }
        host.addSubview(actionBar)
        if let parkedOverlay { host.addSubview(parkedOverlay) }
        if overlay != nil {
            host.addSubview(shield)
            if newLayout == .split { glassContent.addSubview(fieldShield) } else { fieldShield.removeFromSuperview() }
        }
        if let overlay { host.addSubview(overlay) }
        if newLayout == .single {
            resultsGlass.removeFromSuperview()
            resultsGlass.alphaValue = 0
        }
        root.pieces = glassPieces
        if let focus = focus as? NSView, focus.window === panel, currentFocus !== focus {
            panel.makeFirstResponder(focus)
        }
        return true
    }

    private func layoutFixedParts() {
        let width = CGFloat(theme.panel.width)
        let queryHeight = CGFloat(theme.queryRow.height)
        queryField.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        let scale = panel.backingScaleFactor
        let hairlineHeight = CGFloat(theme.panel.hairlinePixels) / scale
        hairline.frame = CGRect(x: 0, y: queryHeight - hairlineHeight, width: width, height: hairlineHeight)
        let barHeight = CGFloat(theme.feedback.loadingBarHeight)
        if layout == .split {
            // Along the straight part of the capsule's bottom edge, clear of its round ends.
            let inset = CGFloat(theme.fieldCornerRadius)
            loadingBar.frame = CGRect(
                x: inset, y: queryHeight - barHeight, width: max(0, width - inset * 2), height: barHeight)
        } else {
            loadingBar.frame = CGRect(x: 0, y: queryHeight - barHeight, width: width, height: barHeight)
        }
        fieldShade.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        content?.frame = CGRect(x: 0, y: contentTop, width: width, height: theme.panel.maxContentHeight)
    }

    private func applyGlassHeight(_ height: CGFloat) {
        let width = CGFloat(theme.panel.width)
        let hostHeight = hostHeight(forGlassHeight: height)
        if layout == .split {
            glass.frame = geometry.fieldFrame
            // A container shorter than a point would draw nothing worth seeing. It stays in the
            // window, laid out at a full height, and hides by opacity, so the summoner can render
            // it while the panel is invisible, it never pays a first render on a keystroke, and it
            // has its key look whenever it shows.
            let shows = hostHeight >= 1
            let height = shows ? hostHeight : CGFloat(theme.panel.maxContentHeight)
            let frame = geometry.resultsFrame(height: Double(height))
            if resultsGlass.frame != frame { resultsGlass.frame = frame }
            let radius = min(CGFloat(theme.panel.cornerRadius), height / 2)
            if resultsGlass.cornerRadius != radius { resultsGlass.cornerRadius = radius }
            if resultsGlass.alphaValue != (shows ? 1 : 0) { resultsGlass.alphaValue = shows ? 1 : 0 }
        } else {
            glass.frame = geometry.glassFrame(height: Double(height))
        }
        // The bar rides the bottom edge of the glass while it animates.
        let barHeight = CGFloat(theme.actionBar.height)
        actionBar.frame = CGRect(x: 0, y: hostHeight - actionBarRoom, width: width, height: barHeight)
        // Most themes draw neither rim nor extra shadow; they skip the shapes on every tick.
        if !shadowDecor.isHidden || !rimDecor.isHidden {
            let shapes = visibleShapes
            shadowDecor.update(shapes)
            rimDecor.update(shapes)
        }
        guard overlay != nil else { return }
        shield.frame = CGRect(x: 0, y: 0, width: width, height: hostHeight)
        fieldShield.frame = glassContent.bounds
        layoutOverlay(hostHeight: hostHeight)
    }

    /// The pieces that show now, for the shadow and the rim.
    private var visibleShapes: [GlassShape] {
        glassPieces.filter { $0.alphaValue > 0 }.map { GlassShape(frame: $0.frame, cornerRadius: $0.cornerRadius) }
    }

    /// The view with keyboard focus: the text field being edited rather than its field editor.
    var currentFocus: NSResponder? {
        let responder = panel.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            return field
        }
        return responder
    }
}
