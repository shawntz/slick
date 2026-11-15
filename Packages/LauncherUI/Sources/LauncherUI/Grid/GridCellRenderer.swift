import AppKit
import CoreText

/// One cell's text, typeset and placed relative to the cell's top-left corner. Built when a cell
/// changes and reused while the grid scrolls.
struct GridCellTypeset {
    var glyph: RowTypeset.PlacedLine?
    var title: RowTypeset.PlacedLine?
    var subtitle: RowTypeset.PlacedLine?
    /// A colour cell's swatch, resolved for the appearance.
    var swatch: CGColor?
}

/// Typesets and draws grid cells with Core Text into a flipped context.
enum GridCellRenderer {
    static func typeset(
        _ cell: GridCell, layout: GridLayout, showsTitles: Bool, emphasizesMatches: Bool, glyphFont: CTFont,
        theme: ResolvedTheme, scale: CGFloat
    ) -> GridCellTypeset {
        let metrics = theme.theme.grid
        let width = CGFloat(layout.cellWidth)
        let tileHeight = CGFloat(layout.tileHeight)
        var typeset = GridCellTypeset()
        if case .color(let color) = cell.content { typeset.swatch = color.cgColor(in: theme.appearance) }
        if case .glyph(let text) = cell.content, !text.isEmpty {
            let line = CTLineCreateWithAttributedString(
                RowTypesetter.attributed(text, font: glyphFont, color: theme.title))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let fitted = RowTypesetter.truncate(line, to: width, font: glyphFont, color: theme.title)
            typeset.glyph = .init(
                line: fitted,
                origin: CGPoint(
                    x: RowTypesetter.snap((width - min(lineWidth, width)) / 2, scale),
                    y: RowTypesetter.snap((tileHeight - ascent - descent) / 2 + ascent, scale)))
        }
        guard showsTitles else { return typeset }
        let style = theme.grid
        var top = tileHeight + CGFloat(metrics.titleGap)
        if !cell.title.isEmpty {
            let string = RowTypesetter.emphasized(
                cell.title, highlights: cell.titleHighlights, emphasizesMatches: emphasizesMatches,
                font: style.titleFont, theme: theme)
            typeset.title = centered(
                CTLineCreateWithAttributedString(string), width: width, top: top,
                height: CGFloat(metrics.titleHeight), font: style.titleFont, color: theme.title, scale: scale)
        }
        top += CGFloat(metrics.titleHeight)
        if !cell.subtitle.isEmpty {
            let line = CTLineCreateWithAttributedString(
                RowTypesetter.attributed(cell.subtitle, font: style.subtitleFont, color: theme.subtitle))
            typeset.subtitle = centered(
                line, width: width, top: top, height: CGFloat(metrics.subtitleHeight), font: style.subtitleFont,
                color: theme.subtitle, scale: scale)
        }
        return typeset
    }

    /// Draws a cell whose top-left corner is `origin`.
    static func draw(
        _ cell: GridCell, typeset: GridCellTypeset, at origin: CGPoint, layout: GridLayout, in context: CGContext,
        theme: ResolvedTheme, roundsImages: Bool
    ) {
        let metrics = theme.theme.grid
        let tile = CGRect(x: 0, y: 0, width: layout.cellWidth, height: layout.tileHeight)
        let radius = CGFloat(metrics.tileCornerRadius)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        fill(tile, radius: radius, color: theme.grid.tileFill, in: context)
        let inner = tile.insetBy(dx: CGFloat(metrics.imagePadding), dy: CGFloat(metrics.imagePadding))
        let innerRadius = max(0, radius - CGFloat(metrics.imagePadding) / 2)
        switch cell.content {
        case .image(let image?):
            let fitted = aspectFit(CGSize(width: image.width, height: image.height), in: inner)
            if roundsImages {
                // Pictures get the tile's rounded corners. A glyph grid's images, such as emoji
                // from the icon atlas, have their own shape and are drawn without the clip.
                context.saveGState()
                context.addPath(
                    CGPath(roundedRect: fitted, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
                context.clip()
                RowRenderer.drawImage(image, in: fitted, context: context)
                context.restoreGState()
            } else {
                RowRenderer.drawImage(image, in: fitted, context: context)
            }
        case .color:
            if let swatch = typeset.swatch { fill(inner, radius: innerRadius, color: swatch, in: context) }
        case .image(nil), .glyph:
            break
        }
        if let glyph = typeset.glyph { RowRenderer.draw(glyph, context) }
        RowRenderer.withHalo(theme, context) {
            if let title = typeset.title { RowRenderer.draw(title, context) }
            if let subtitle = typeset.subtitle { RowRenderer.draw(subtitle, context) }
        }
        context.restoreGState()
    }

    /// The largest rectangle of `size`'s shape that fits in `rect`, centred and pixel-rounded.
    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return CGRect(
            x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(), width: width, height: height)
    }

    private static func fill(_ rect: CGRect, radius: CGFloat, color: CGColor, in context: CGContext) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    private static func centered(
        _ line: CTLine, width: CGFloat, top: CGFloat, height: CGFloat, font: CTFont, color: CGColor, scale: CGFloat
    ) -> RowTypeset.PlacedLine {
        let fitted = RowTypesetter.truncate(line, to: width, font: font, color: color)
        return RowTypesetter.centered(
            fitted, in: CGRect(x: 0, y: top, width: width, height: height), font: font, scale: scale)
    }
}
