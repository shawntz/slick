import AppKit
import CoreText

/// The detail pane's non-text body: an image, a colour swatch, or a file's thumbnail and name.
final class DetailVisualView: NSView {
    enum Visual: Equatable {
        case image(CGImage?)
        case color(ThemeColor, caption: String?)
        case file(name: String, thumbnail: CGImage?)

        static func == (lhs: Visual, rhs: Visual) -> Bool {
            switch (lhs, rhs) {
            case (.image(let a), .image(let b)): a === b
            case (.color(let a, let captionA), .color(let b, let captionB)): a == b && captionA == captionB
            case (.file(let a, let thumbA), .file(let b, let thumbB)): a == b && thumbA === thumbB
            default: false
            }
        }
    }

    var visual: Visual = .image(nil) {
        didSet { if visual != oldValue { resolveSwatch() } }
    }

    private var theme: ResolvedTheme?
    private var swatch: CGColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        resolveSwatch()
    }

    /// The height this visual wants at `width`; images take whatever height they are given.
    func preferredHeight(width: CGFloat) -> CGFloat? {
        guard let theme else { return nil }
        let metrics = theme.theme.detail
        let caption = CGFloat(theme.theme.fonts.detailText.size) * 2
        switch visual {
        case .image: return nil
        case .color(_, let text):
            return CGFloat(metrics.padding * 2 + metrics.swatchHeight) + (text == nil ? 0 : caption)
        case .file: return CGFloat(metrics.padding * 2 + metrics.thumbnailSize) + caption
        }
    }

    private func resolveSwatch() {
        if case .color(let color, let caption) = visual, let theme {
            swatch = color.cgColor(in: theme.appearance)
            setAccessibilityLabel(caption)
        } else {
            swatch = nil
        }
        if case .file(let name, _) = visual { setAccessibilityLabel(name) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        let metrics = theme.theme.detail
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(metrics.padding)
        let radius = CGFloat(metrics.swatchCornerRadius)
        switch visual {
        case .image(let image):
            guard let image else { return }
            let box = bounds.insetBy(dx: CGFloat(metrics.imagePadding), dy: CGFloat(metrics.imagePadding))
            let fitted = GridCellRenderer.aspectFit(CGSize(width: image.width, height: image.height), in: box)
            context.saveGState()
            context.addPath(CGPath(roundedRect: fitted, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            RowRenderer.drawImage(image, in: fitted, context: context)
            context.restoreGState()
        case .color(_, let caption):
            let rect = CGRect(
                x: padding, y: padding, width: bounds.width - padding * 2, height: CGFloat(metrics.swatchHeight))
            if let swatch {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(swatch)
                context.fillPath()
            }
            if let caption { drawCaption(caption, below: rect, theme: theme, context: context, scale: scale) }
        case .file(let name, let thumbnail):
            let size = CGFloat(metrics.thumbnailSize)
            let rect = CGRect(x: ((bounds.width - size) / 2).rounded(), y: padding, width: size, height: size)
            if let thumbnail {
                let fitted = GridCellRenderer.aspectFit(
                    CGSize(width: thumbnail.width, height: thumbnail.height), in: rect)
                RowRenderer.drawImage(thumbnail, in: fitted, context: context)
            } else {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(theme.iconPlaceholder)
                context.fillPath()
            }
            drawCaption(name, below: rect, theme: theme, context: context, scale: scale)
        }
    }

    private func drawCaption(
        _ text: String, below rect: CGRect, theme: ResolvedTheme, context: CGContext, scale: CGFloat
    ) {
        let font = theme.titleFont
        let line = RowTypesetter.truncate(
            CTLineCreateWithAttributedString(RowTypesetter.attributed(text, font: font, color: theme.detail.textColor)),
            to: rect.width, font: font, color: theme.detail.textColor)
        let frame = CGRect(
            x: rect.minX, y: rect.maxY + 6, width: rect.width, height: CGFloat(theme.theme.fonts.detailText.size) * 2)
        RowRenderer.draw(RowTypesetter.centered(line, in: frame, font: font, scale: scale), context)
    }
}
