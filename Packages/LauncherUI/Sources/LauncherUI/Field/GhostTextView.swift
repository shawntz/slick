import AppKit
import CoreText

/// The ghost completion: text drawn after the typed text in the placeholder colour.
///
/// It draws with Core Text and redraws only when its text changes; moving it costs nothing. A
/// vibrant label here cost about 2 ms per keystroke, because every update went through text
/// field layout.
final class GhostTextView: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    /// Distance from the top of the view to the text's baseline.
    var baseline: CGFloat = 0 {
        didSet { if baseline != oldValue { needsDisplay = true } }
    }
    private var font: CTFont = NSFont.systemFont(ofSize: 23) as CTFont
    private var color = CGColor(gray: 0.5, alpha: 0.5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .left
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: ResolvedTheme) {
        style(font: theme.queryFont as CTFont, color: theme.ghostText)
    }

    /// Draws in another font, for ghosts outside the query field.
    func style(font: CTFont, color: CGColor) {
        self.font = font
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(RowTypesetter.attributed(text, font: font, color: color))
        let fitted = RowTypesetter.truncate(line, to: bounds.width, font: font, color: color)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(fitted, context)
    }
}
