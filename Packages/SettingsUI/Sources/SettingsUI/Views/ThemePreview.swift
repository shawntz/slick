import AppKit
import LauncherUI
import SwiftUI

/// The launcher drawn with a theme by LauncherUI's own views: the glass, query field, result list,
/// selection lens and action bar, over a synthetic backdrop. It shows made-up rows, and its parts
/// never take a click: the preview is a picture. With ``onClick`` set, as on onboarding's theme
/// tiles, the whole preview takes the click itself and runs it, in AppKit, so the click works the
/// same whatever SwiftUI puts around it.
///
/// It lays the panel out at the theme's real size and scales it to fit, so what the user sees is
/// what the panel draws: the glass in the theme's style, one piece or the query row apart from a
/// results container, with the theme's shade, rim and shadow.
final class ThemePreviewView: NSView {
    static let margin: CGFloat = 28
    static let rowCount = 5

    private let backdrop = PreviewBackdrop()
    private let glassShadow = GlassShadowView()
    private let rim = GlassRimView()
    private let shade = FieldShadeView()
    private let glass = NSGlassEffectView()
    private let glassContent = PreviewFlippedView()
    private let resultsGlass = NSGlassEffectView()
    private let resultsContent = PreviewFlippedView()
    // Internal for the shot tests, which compose these parts into a bitmap themselves.
    let queryField = QueryField()
    let hairline = NSView()
    let list = ResultListView()
    let actionBar = ActionBar()
    let lens = SelectionLens(style: Theme.standard.lens.style)
    private(set) var theme = Theme.standard
    /// The display's accessibility settings the preview draws for. Nil follows the system, as the
    /// panel does. A test sets it, so what it sees does not depend on the Mac that runs it: with
    /// Reduce Transparency on, every theme resolves to regular glass with no tint.
    var accessibilityOverride: DisplayAccessibility? {
        didSet { if accessibilityOverride != oldValue { restyle() } }
    }
    private var logicalSize = CGSize(width: 1, height: 1)
    private var isStyled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Bottom to top, as the panel stacks them: the shadow, the results container, the query
        // row's glass, then the rim over both edges.
        for view in [backdrop, glassShadow, resultsGlass, glass, rim] as [NSView] { addSubview(view) }
        glass.contentView = glassContent
        resultsGlass.contentView = resultsContent
        hairline.wantsLayer = true
        for view in [shade, lens.view, queryField, hairline, actionBar] { glassContent.addSubview(view) }
        glassContent.addSubview(list, positioned: .above, relativeTo: lens.view)
        lens.onViewReplaced = { old, new in
            old.superview?.addSubview(new, positioned: .below, relativeTo: old)
            old.removeFromSuperview()
        }
        list.selectionLens = lens
        queryField.placeholder = "Search"
        queryField.text = Self.query
        queryField.ghostText = "endar"
        queryField.textField.isEditable = false
        queryField.textField.isSelectable = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview of the launcher with this theme")
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Runs when the person clicks the preview. Nil leaves it a picture that takes no clicks.
    var onClick: (() -> Void)?

    // Clicks never reach the field or the list. Without an action, they pass the preview by.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, !isHidden, frame.contains(point) else { return nil }
        return self
    }

    // A tile in a window that is not key selects on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) {
        guard onClick == nil else { return }
        super.mouseDown(with: event)
    }

    // A click counts when the button comes up over the preview, as a button's does.
    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(logicalSize)
    }

    /// The size the preview lays out at before scaling, for a theme.
    static func logicalSize(for theme: Theme) -> CGSize {
        let content = previewContentHeight(theme)
        let margins = margins(for: theme)
        return CGSize(
            width: theme.panel.width + margins.left + margins.right,
            height: theme.glassHeight(contentHeight: content) + margins.top + margins.bottom)
    }

    /// The room around the glass: the panel's own shadow insets for a theme that casts a shadow of
    /// its own, so the preview does not cut it, and a fixed margin otherwise.
    static func margins(for theme: Theme) -> ThemeInsets {
        guard theme.panel.shadowRadius > 0 else {
            return ThemeInsets(top: margin, left: margin, bottom: margin, right: margin)
        }
        return theme.panel.shadowInsets
    }

    /// The pieces of glass the preview shows now, the query row's first.
    var glassPieces: [NSGlassEffectView] { resultsGlass.isHidden ? [glass] : [glass, resultsGlass] }

    private static func previewContentHeight(_ theme: Theme) -> Double {
        theme.list.verticalPadding * 2 + theme.list.sectionHeaderHeight + Double(rowCount) * theme.list.rowHeight
    }

    /// Draws the preview with a theme. The same theme again does nothing, so SwiftUI updates that
    /// change something else cost nothing here.
    func apply(theme: Theme) {
        guard theme != self.theme || !isStyled else { return }
        isStyled = true
        self.theme = theme
        logicalSize = Self.logicalSize(for: theme)
        setBoundsSize(logicalSize)
        restyle()
    }

    private func restyle() {
        let resolved = ResolvedTheme(
            theme: theme, appearance: effectiveAppearance, accessibility: accessibilityOverride ?? .current)
        let width = CGFloat(theme.panel.width)
        let queryHeight = CGFloat(theme.queryRow.height)
        let contentHeight = CGFloat(Self.previewContentHeight(theme))
        let glassHeight = CGFloat(theme.glassHeight(contentHeight: Double(contentHeight)))
        let barHeight = CGFloat(theme.actionBar.height)
        let barRoom = CGFloat(theme.actionBarHeight(showsToast: false))
        let split = theme.panel.layout == .split
        let margins = Self.margins(for: theme)
        let origin = CGPoint(x: margins.left, y: margins.top)

        backdrop.frame = CGRect(origin: .zero, size: logicalSize)
        backdrop.isDark = resolved.isDark
        backdrop.update()
        for piece in [glass, resultsGlass] where piece.style != resolved.glassStyle {
            piece.style = resolved.glassStyle
        }
        // The content side lives in the results container when the theme splits the glass.
        let host = split ? resultsContent : glassContent
        if list.superview !== host {
            host.addSubview(lens.view)
            host.addSubview(list, positioned: .above, relativeTo: lens.view)
            host.addSubview(actionBar)
        }
        let resultsTop = queryHeight + (split ? CGFloat(theme.panel.fieldGap) : 0)
        resultsGlass.isHidden = !split
        if split {
            glass.frame = CGRect(origin: origin, size: CGSize(width: width, height: queryHeight))
            glass.cornerRadius = CGFloat(theme.fieldCornerRadius)
            glass.tintColor = resolved.fieldTint
            resultsGlass.frame = CGRect(
                x: origin.x, y: origin.y + resultsTop, width: width, height: glassHeight - resultsTop)
            resultsGlass.cornerRadius = CGFloat(theme.panel.cornerRadius)
            resultsGlass.tintColor = resolved.glassTint
            resultsContent.frame = CGRect(origin: .zero, size: resultsGlass.frame.size)
        } else {
            glass.frame = CGRect(origin: origin, size: CGSize(width: width, height: glassHeight))
            glass.cornerRadius = CGFloat(theme.panel.cornerRadius)
            glass.tintColor = resolved.glassTint
        }
        glassContent.frame = CGRect(origin: .zero, size: glass.frame.size)
        shade.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        shade.apply(color: split ? resolved.fieldShade : nil, cornerRadius: CGFloat(theme.fieldCornerRadius))
        queryField.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        let hairlineHeight = CGFloat(theme.panel.hairlinePixels) / max(window?.backingScaleFactor ?? 2, 1)
        hairline.frame = CGRect(x: 0, y: queryHeight - hairlineHeight, width: width, height: hairlineHeight)
        hairline.layer?.backgroundColor = resolved.hairline
        hairline.isHidden = split
        let contentTop = split ? 0 : queryHeight
        list.frame = CGRect(x: 0, y: contentTop, width: width, height: contentHeight)
        let hostHeight = split ? resultsGlass.frame.height : glassHeight
        actionBar.frame = CGRect(x: 0, y: hostHeight - barRoom, width: width, height: barHeight)
        actionBar.isHidden = barRoom == 0
        for decor in [glassShadow, rim] as [NSView] { decor.frame = CGRect(origin: .zero, size: logicalSize) }
        glassShadow.apply(
            color: resolved.shadow, radius: CGFloat(theme.panel.shadowRadius), offset: CGFloat(theme.panel.shadowOffset)
        )
        rim.apply(color: resolved.rim, width: CGFloat(theme.panel.rimWidth))
        let shapes = glassPieces.map { GlassShape(frame: $0.frame, cornerRadius: $0.cornerRadius) }
        glassShadow.update(shapes)
        rim.update(shapes)

        queryField.apply(resolved)
        actionBar.apply(resolved)
        lens.apply(resolved)
        list.apply(resolved)
        list.apply(PreviewContent.content)
        list.select(0, animated: false)
        actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: "Open Application"))
    }

    private static let query = "cal"
}

/// The made-up rows the preview shows.
private enum PreviewContent {
    static let content: ListContent = {
        let rows: [ListRow] = [
            row(1, "Calendar", 0, "Application", [.keycaps(["⌘", "1"])], "calendar", 0.0),
            row(
                2, "Calculator", 0, "Application", [.tag("Running", color: ThemeColor(.green))],
                "plus.forwardslash.minus", 0.58),
            row(3, "Local Weather", 2, "Command", [.text("Alias: lw")], "cloud.sun.fill", 0.12),
            row(4, "Vocal Notes", 2, "Application", [.text("Yesterday")], "mic.fill", 0.8),
            row(5, "Scale Image", 2, "Command", [], "photo.fill", 0.35),
        ]
        return ListContent(sections: [LauncherUI.ListSection(title: "Results", rows: rows)], emphasizesMatches: true)
    }()

    private static func row(
        _ id: UInt64, _ title: String, _ match: Int, _ subtitle: String, _ accessories: [RowAccessory],
        _ symbol: String,
        _ hue: Double
    ) -> ListRow {
        ListRow(
            id: id, title: title, titleHighlights: [HighlightRange(location: match, length: 3)], subtitle: subtitle,
            accessories: accessories, icon: icon(symbol, hue: hue))
    }

    /// A rounded square in a colour with a white symbol, drawn in memory.
    private static func icon(_ symbol: String, hue: Double) -> CGImage? {
        let pixels = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.addPath(
            CGPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
        context.fillPath()
        let configuration = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            let size = image.size
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(
                in: CGRect(
                    x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2, width: size.width,
                    height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }
}

/// Colour behind the preview's glass, so the glass has something to refract: a gradient and
/// discs in the appearance's tones. It is made of Core Animation layers, so it draws the same on
/// screen and in a bitmap.
private final class PreviewBackdrop: NSView {
    private let gradient = CAGradientLayer()
    private let discs: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }
    private static let places: [(x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor)] = [
        (0.12, 0.25, 0.22, .systemTeal), (0.78, 0.18, 0.18, .systemPink), (0.55, 0.85, 0.26, .systemYellow),
        (0.3, 0.7, 0.14, .systemIndigo),
    ]

    var isDark = false {
        didSet { if isDark != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
        for disc in discs { layer?.addSublayer(disc) }
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        update()
    }

    func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        gradient.frame = bounds
        gradient.colors =
            isDark
            ? [
                CGColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1),
                CGColor(srgbRed: 0.28, green: 0.12, blue: 0.30, alpha: 1),
            ]
            : [
                CGColor(srgbRed: 0.62, green: 0.78, blue: 0.95, alpha: 1),
                CGColor(srgbRed: 0.96, green: 0.76, blue: 0.62, alpha: 1),
            ]
        for (disc, place) in zip(discs, Self.places) {
            let side = bounds.width * place.size
            let rect = CGRect(
                x: bounds.width * place.x - side / 2, y: bounds.height * place.y - side / 2, width: side, height: side)
            disc.path = CGPath(ellipseIn: rect, transform: nil)
            disc.fillColor = place.color.withAlphaComponent(isDark ? 0.45 : 0.6).cgColor
        }
    }
}

private final class PreviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The preview in SwiftUI. `dark` forces an appearance; nil follows the window. `onClick` makes
/// the preview take clicks and run it; nil leaves it a picture.
struct ThemePreview: NSViewRepresentable {
    let theme: Theme
    var dark: Bool?
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> ThemePreviewView {
        ThemePreviewView(frame: .zero)
    }

    func updateNSView(_ view: ThemePreviewView, context: Context) {
        view.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        view.onClick = onClick
        view.apply(theme: theme)
    }
}
