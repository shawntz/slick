import AppKit
import CoreText

/// The metadata table under the detail body: a label on the left in the secondary colour, its
/// value on the right, and hairlines between groups. Drawn with Core Text in one view.
final class MetadataView: NSView {
    /// A link value was clicked.
    var onOpenLink: ((URL) -> Void)?

    var items: [MetadataItem] = [] {
        didSet { if items != oldValue { needsDisplay = true } }
    }

    private var theme: ResolvedTheme?
    /// Rendered symbol icons by name, for the current theme and scale.
    private var symbols: [String: CGImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func apply(_ theme: ResolvedTheme) {
        self.theme = theme
        symbols.removeAll()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        symbols.removeAll()
    }

    private func image(for icon: CardIcon, theme: ResolvedTheme) -> CGImage? {
        switch icon {
        case .image(let image): return image
        case .symbol(let name):
            if let cached = symbols[name] { return cached }
            let image = SymbolRenderer.image(
                name, pointSize: CGFloat(theme.theme.list.accessoryIconSize), color: theme.title,
                scale: window?.backingScaleFactor ?? 2)
            symbols[name] = image
            return image
        }
    }

    /// The table's height for `items`.
    func contentHeight() -> CGFloat {
        guard let theme, !items.isEmpty else { return 0 }
        return rows(theme.theme.detail).last.map { $0.y + $0.height } ?? 0
    }

    /// Each item's vertical extent.
    private func rows(_ metrics: DetailMetrics) -> [(item: MetadataItem, y: CGFloat, height: CGFloat)] {
        var y = CGFloat(metrics.metadataGroupGap)
        return items.map { item in
            let height: CGFloat =
                if case .separator = item { CGFloat(metrics.metadataGroupGap) * 2 + 1 } else {
                    CGFloat(metrics.metadataRowHeight)
                }
            defer { y += height }
            return (item, y, height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        context.touchCorners(of: bounds)
        let metrics = theme.theme.detail
        let scale = window?.backingScaleFactor ?? 2
        let padding = CGFloat(metrics.padding)
        let right = bounds.width - padding
        for row in rows(metrics) where row.y < dirtyRect.maxY && row.y + row.height > dirtyRect.minY {
            guard let label = Self.label(of: row.item) else {
                context.setFillColor(theme.hairline)
                context.fill(
                    CGRect(x: padding, y: (row.y + row.height / 2).rounded(), width: right - padding, height: 1 / scale)
                )
                continue
            }
            let labelFont = theme.detail.metadataLabelFont
            let labelLine = RowTypesetter.truncate(
                CTLineCreateWithAttributedString(
                    RowTypesetter.attributed(label, font: labelFont, color: theme.subtitle)),
                to: (right - padding) * 0.45, font: labelFont, color: theme.subtitle)
            let baseline = RowTypesetter.snap(
                row.y + RowTypesetter.baseline(centering: labelFont, in: row.height), scale)
            let valueLeft = padding + RowTypesetter.lineWidth(labelLine) + CGFloat(theme.theme.list.accessoryGap)
            // Only text takes the halo: swatches, tag fills, the link underline and icons would
            // gain a shadow, and under a halo of two layers they would be drawn twice.
            RowRenderer.withHalo(theme, context) {
                RowRenderer.draw(.init(line: labelLine, origin: CGPoint(x: padding, y: baseline)), context)
            }
            drawValue(
                row.item, left: valueLeft, right: right, rowY: row.y, rowHeight: row.height, theme: theme,
                context: context, scale: scale)
        }
    }

    private func drawValue(
        _ item: MetadataItem, left: CGFloat, right: CGFloat, rowY: CGFloat, rowHeight: CGFloat, theme: ResolvedTheme,
        context: CGContext, scale: CGFloat
    ) {
        let font = theme.detail.metadataValueFont
        let baseline = RowTypesetter.snap(rowY + RowTypesetter.baseline(centering: font, in: rowHeight), scale)
        func text(_ string: String, color: CGColor, right: CGFloat) -> CGFloat {
            let line = RowTypesetter.truncate(
                CTLineCreateWithAttributedString(RowTypesetter.attributed(string, font: font, color: color)),
                to: max(0, right - left), font: font, color: color)
            let x = right - RowTypesetter.lineWidth(line)
            RowRenderer.withHalo(theme, context) {
                RowRenderer.draw(.init(line: line, origin: CGPoint(x: x, y: baseline)), context)
            }
            return x
        }
        switch item {
        case .label(_, let value): _ = text(value, color: theme.title, right: right)
        case .iconLabel(_, let value, let icon):
            let x = text(value, color: theme.title, right: right)
            let size = CGFloat(theme.theme.list.accessoryIconSize)
            let frame = CGRect(
                x: x - size - CGFloat(theme.theme.list.accessorySpacing),
                y: RowTypesetter.snap(rowY + (rowHeight - size) / 2, scale), width: size, height: size)
            if frame.minX >= left, let image = image(for: icon, theme: theme) {
                RowRenderer.drawImage(image, in: frame, context: context)
            }
        case .link(_, let value, _):
            // Body-coloured text with an accent underline, as links in the body have.
            let x = text(value, color: theme.title, right: right)
            context.setFillColor(theme.detail.linkColor)
            context.fill(
                CGRect(
                    x: x, y: baseline - CTFontGetUnderlinePosition(font), width: right - x,
                    height: max(1 / scale, CTFontGetUnderlineThickness(font))))
        case .color(_, let color, let value):
            let x = text(value, color: theme.title, right: right)
            let size = CGFloat(theme.theme.list.accessoryIconSize)
            let swatch = CGRect(
                x: x - size - CGFloat(theme.theme.list.accessorySpacing), y: rowY + ((rowHeight - size) / 2).rounded(),
                width: size, height: size)
            context.addPath(CGPath(roundedRect: swatch, cornerWidth: size / 4, cornerHeight: size / 4, transform: nil))
            context.setFillColor(color.cgColor(in: theme.appearance))
            context.fillPath()
        case .tags(_, let tags):
            let list = theme.theme.list
            var x = right
            for tag in tags.reversed() {
                let colors = theme.tagColors(tag.color)
                let line = CTLineCreateWithAttributedString(
                    RowTypesetter.attributed(tag.text, font: theme.tagFont, color: colors.text))
                let width = ceil(RowTypesetter.lineWidth(line) + CGFloat(list.tagPadding) * 2)
                guard x - width >= left else { break }
                let frame = CGRect(
                    x: x - width, y: RowTypesetter.snap(rowY + (rowHeight - CGFloat(list.tagHeight)) / 2, scale),
                    width: width, height: CGFloat(list.tagHeight))
                context.addPath(
                    CGPath(
                        roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2,
                        transform: nil))
                context.setFillColor(colors.fill)
                context.fillPath()
                RowRenderer.withHalo(theme, context) {
                    RowRenderer.draw(
                        RowTypesetter.centered(line, in: frame, font: theme.tagFont, scale: scale), context)
                }
                x = frame.minX - CGFloat(list.accessorySpacing)
            }
        case .separator: break
        }
    }

    private static func label(of item: MetadataItem) -> String? {
        switch item {
        case .label(let label, _), .link(let label, _, _), .tags(let label, _), .color(let label, _, _),
            .iconLabel(let label, _, _):
            label
        case .separator: nil
        }
    }

    // MARK: Pointer and accessibility

    override func mouseDown(with event: NSEvent) {
        guard let theme else { return }
        let point = convert(event.locationInWindow, from: nil)
        for row in rows(theme.theme.detail) where point.y >= row.y && point.y < row.y + row.height {
            if case .link(_, _, let target) = row.item, let url = URL(string: target) { onOpenLink?(url) }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        items.compactMap { item -> NSAccessibilityElement? in
            guard let label = Self.label(of: item) else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            let value: String =
                switch item {
                case .label(_, let value), .link(_, let value, _), .color(_, _, let value), .iconLabel(_, let value, _):
                    value
                case .tags(_, let tags): tags.map(\.text).joined(separator: ", ")
                case .separator: ""
                }
            element.setAccessibilityLabel("\(label): \(value)")
            return element
        }
    }
}
