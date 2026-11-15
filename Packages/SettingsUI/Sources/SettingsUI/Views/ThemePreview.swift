import AppKit
import LauncherUI
import SwiftUI

/// The launcher drawn with a theme by LauncherUI's own views: the glass, query field, result list,
/// selection lens and action bar, over a synthetic backdrop. It shows made-up rows and is not
/// interactive.
///
/// It lays the panel out at the theme's real size and scales it to fit, so what the user sees is
/// what the panel draws.
final class ThemePreviewView: NSView {
    static let margin: CGFloat = 28
    static let rowCount = 5

    private let backdrop = PreviewBackdrop()
    private let glass = NSGlassEffectView()
    private let glassContent = PreviewFlippedView()
    // Internal for the shot tests, which compose these parts into a bitmap themselves.
    let queryField = QueryField()
    let hairline = NSView()
    let list = ResultListView()
    let actionBar = ActionBar()
    let lens = SelectionLens(style: Theme.standard.lens.style)
    private(set) var theme = Theme.standard
    private var logicalSize = CGSize(width: 1, height: 1)
    private var isStyled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(backdrop)
        addSubview(glass)
        glass.style = .regular
        glass.contentView = glassContent
        hairline.wantsLayer = true
        for view in [lens.view, queryField, hairline, actionBar] { glassContent.addSubview(view) }
        glassContent.addSubview(list, positioned: .above, relativeTo: lens.view)
        lens.onViewReplaced = { [weak self] old, new in
            self?.glassContent.addSubview(new, positioned: .below, relativeTo: old)
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

    // The preview is a picture: clicks never reach the field or the list.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        return CGSize(
            width: theme.panel.width + margin * 2, height: theme.glassHeight(contentHeight: content) + margin * 2)
    }

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
        let resolved = ResolvedTheme(theme: theme, appearance: effectiveAppearance, accessibility: .current)
        let width = CGFloat(theme.panel.width)
        let queryHeight = CGFloat(theme.queryRow.height)
        let contentHeight = CGFloat(Self.previewContentHeight(theme))
        let glassHeight = CGFloat(theme.glassHeight(contentHeight: Double(contentHeight)))
        let barHeight = CGFloat(theme.actionBar.height)

        backdrop.frame = CGRect(origin: .zero, size: logicalSize)
        backdrop.isDark = resolved.isDark
        backdrop.update()
        glass.frame = CGRect(x: Self.margin, y: Self.margin, width: width, height: glassHeight)
        glass.cornerRadius = CGFloat(theme.panel.cornerRadius)
        glass.tintColor = resolved.glassTint
        glassContent.frame = CGRect(x: 0, y: 0, width: width, height: glassHeight)
        queryField.frame = CGRect(x: 0, y: 0, width: width, height: queryHeight)
        let hairlineHeight = CGFloat(theme.panel.hairlinePixels) / max(window?.backingScaleFactor ?? 2, 1)
        hairline.frame = CGRect(x: 0, y: queryHeight - hairlineHeight, width: width, height: hairlineHeight)
        hairline.layer?.backgroundColor = resolved.hairline
        list.frame = CGRect(x: 0, y: queryHeight, width: width, height: contentHeight)
        actionBar.frame = CGRect(x: 0, y: glassHeight - barHeight, width: width, height: barHeight)

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

/// The preview in SwiftUI. `dark` forces an appearance; nil follows the window.
struct ThemePreview: NSViewRepresentable {
    let theme: Theme
    var dark: Bool?

    func makeNSView(context: Context) -> ThemePreviewView {
        ThemePreviewView(frame: .zero)
    }

    func updateNSView(_ view: ThemePreviewView, context: Context) {
        view.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        view.apply(theme: theme)
    }
}
