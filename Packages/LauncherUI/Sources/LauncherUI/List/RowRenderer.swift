import AppKit
import CoreText

/// Draws typeset rows and section headers into a flipped context.
enum RowRenderer {
    static func drawRow(
        _ typeset: RowTypeset, icon: CGImage?, at origin: CGPoint, in context: CGContext, theme: ResolvedTheme
    ) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if let icon {
            drawImage(icon, in: typeset.iconFrame, context: context)
        } else {
            let radius = CGFloat(theme.theme.list.iconPlaceholderRadius)
            context.addPath(
                CGPath(roundedRect: typeset.iconFrame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(theme.iconPlaceholder)
            context.fillPath()
        }
        withHalo(theme, context) {
            draw(typeset.title, context)
            if let subtitle = typeset.subtitle { draw(subtitle, context) }
        }
        for accessory in typeset.accessories { draw(accessory, context: context, theme: theme) }
        context.restoreGState()
    }

    static func drawHeader(_ title: String, top: CGFloat, in context: CGContext, theme: ResolvedTheme, scale: CGFloat) {
        let metrics = theme.theme.list
        let line = CTLineCreateWithAttributedString(
            RowTypesetter.attributed(title, font: theme.sectionHeaderFont, color: theme.sectionHeader)
        )
        let baseline = RowTypesetter.snap(top + CGFloat(metrics.sectionHeaderBaseline), scale)
        withHalo(theme, context) {
            draw(.init(line: line, origin: CGPoint(x: metrics.sectionHeaderX, y: baseline)), context)
        }
    }

    private static func draw(_ accessory: RowTypeset.Accessory, context: CGContext, theme: ResolvedTheme) {
        switch accessory {
        case .text(let line):
            withHalo(theme, context) { draw(line, context) }
        case .capsule(let frame, let radius, let fill, let text):
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(fill)
            context.fillPath()
            draw(text, context)
        case .group(let parts):
            for part in parts { draw(part, context: context, theme: theme) }
        case .image(let image, let frame):
            drawImage(image, in: frame, context: context)
        }
    }

    /// Draws a placed line into a flipped context.
    static func draw(_ placed: RowTypeset.PlacedLine, _ context: CGContext) {
        // The view is flipped; Core Text draws upright only in an unflipped text matrix.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = placed.origin
        CTLineDraw(placed.line, context)
    }

    /// Draws an image upright into `rect` of a flipped context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// Draws `body` with the theme's text halo, when it has one.
    static func withHalo(_ theme: ResolvedTheme, _ context: CGContext, _ body: () -> Void) {
        guard let halo = theme.textHalo else {
            body()
            return
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: CGFloat(theme.palette.textHaloRadius), color: halo)
        body()
        context.restoreGState()
    }
}
