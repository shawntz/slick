import AppKit
import CoreText

/// A button inside a card: a rounded fill, a title and the key that presses it as a keycap.
///
/// Drawn with Core Text, so its contrast comes from the theme like the rows'. A prominent
/// button uses the accent fill, a destructive one the destructive fill; both draw their text in
/// the on-prominent colour.
final class CardButton: NSView {
    enum Role {
        case plain, prominent, destructive
    }

    var title: String {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    var role: Role {
        didSet { if role != oldValue { needsDisplay = true } }
    }
    /// The key hint drawn after the title, such as "esc" or "↩". Empty draws none.
    var key: String
    var onPress: (() -> Void)?

    private var theme: ResolvedTheme?

    init(title: String, key: String, role: Role) {
        self.title = title
        self.key = key
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        needsDisplay = true
    }

    /// The width the title and keycap need.
    var fittingWidth: CGFloat {
        guard let theme else { return 0 }
        let card = theme.theme.card
        let parts = lines(theme)
        let cap = key.isEmpty ? 0 : CGFloat(card.buttonPadding) + keycapWidth(parts.key, theme)
        return ceil(RowTypesetter.lineWidth(parts.title) + CGFloat(card.buttonPadding) * 2 + cap)
    }

    private func lines(_ theme: ResolvedTheme) -> (title: CTLine, key: CTLine) {
        let text = textColor(theme)
        return (
            CTLineCreateWithAttributedString(RowTypesetter.attributed(title, font: theme.card.buttonFont, color: text)),
            CTLineCreateWithAttributedString(RowTypesetter.attributed(key, font: theme.keycapFont, color: text))
        )
    }

    private func textColor(_ theme: ResolvedTheme) -> CGColor {
        role == .plain ? theme.title : theme.card.onProminent
    }

    private func keycapWidth(_ line: CTLine, _ theme: ResolvedTheme) -> CGFloat {
        let list = theme.theme.list
        return max(CGFloat(list.keycapMinWidth), ceil(RowTypesetter.lineWidth(line) + CGFloat(list.keycapPadding) * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let card = theme.theme.card
        let list = theme.theme.list
        let scale = window?.backingScaleFactor ?? 2
        let radius = CGFloat(card.buttonCornerRadius)
        let fill: CGColor =
            switch role {
            case .plain: theme.keycapFill
            case .prominent: theme.card.prominent
            case .destructive: theme.card.destructive
            }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()

        let parts = lines(theme)
        let padding = CGFloat(card.buttonPadding)
        let titleWidth = RowTypesetter.lineWidth(parts.title)
        let capWidth = key.isEmpty ? 0 : keycapWidth(parts.key, theme)
        let contentWidth = titleWidth + (key.isEmpty ? 0 : padding + capWidth)
        let x = ((bounds.width - contentWidth) / 2).rounded()
        let baseline = RowTypesetter.snap(
            RowTypesetter.baseline(centering: theme.card.buttonFont, in: bounds.height), scale)
        RowRenderer.draw(.init(line: parts.title, origin: CGPoint(x: x, y: baseline)), context)
        guard !key.isEmpty else { return }

        let capHeight = CGFloat(list.keycapHeight)
        let cap = CGRect(
            x: x + titleWidth + padding, y: RowTypesetter.snap((bounds.height - capHeight) / 2, scale), width: capWidth,
            height: capHeight)
        let capRadius = CGFloat(list.keycapRadius)
        context.addPath(CGPath(roundedRect: cap, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil))
        context.setFillColor(role == .plain ? theme.keycapFill : theme.card.onProminentKeycap)
        context.fillPath()
        RowRenderer.draw(RowTypesetter.centered(parts.key, in: cap, font: theme.keycapFont, scale: scale), context)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onPress?() }
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
