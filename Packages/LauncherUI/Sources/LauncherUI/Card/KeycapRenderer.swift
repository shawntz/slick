import AppKit
import CoreText

/// Draws a shortcut as keycaps with Core Text: the same capsules a row's keycap accessory uses,
/// for views that draw their own text.
enum KeycapRenderer {
    /// The width of `keys` drawn as keycaps, spacing included.
    static func width(_ keys: [String], theme: ResolvedTheme) -> CGFloat {
        guard !keys.isEmpty else { return 0 }
        let list = theme.theme.list
        return keys.reduce(0) { $0 + capWidth(line($1, theme), list) } + CGFloat(list.keycapSpacing)
            * CGFloat(keys.count - 1)
    }

    /// Draws `keys` ending at `right`, centred in `height` from `top`. Returns the left edge.
    /// `lines` keeps each key's typeset line for the next draw.
    @discardableResult
    static func draw(
        _ keys: [String], right: CGFloat, top: CGFloat, height: CGFloat, theme: ResolvedTheme, fill: CGColor? = nil,
        context: CGContext, scale: CGFloat, lines: RowLineCache? = nil
    ) -> CGFloat {
        let list = theme.theme.list
        var x = right
        for key in keys.reversed() {
            let text = lines?.line(.init(text: key, role: .keycap)) { line(key, theme) } ?? line(key, theme)
            let width = capWidth(text, list)
            let capHeight = CGFloat(list.keycapHeight)
            let frame = CGRect(
                x: x - width, y: RowTypesetter.snap(top + (height - capHeight) / 2, scale), width: width,
                height: capHeight)
            let radius = CGFloat(list.keycapRadius)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(fill ?? theme.keycapFill)
            context.fillPath()
            RowRenderer.draw(RowTypesetter.centered(text, in: frame, font: theme.keycapFont, scale: scale), context)
            x = frame.minX - CGFloat(list.keycapSpacing)
        }
        return keys.isEmpty ? right : x + CGFloat(list.keycapSpacing)
    }

    private static func line(_ key: String, _ theme: ResolvedTheme) -> CTLine {
        CTLineCreateWithAttributedString(RowTypesetter.attributed(key, font: theme.keycapFont, color: theme.keycapText))
    }

    private static func capWidth(_ line: CTLine, _ list: ListMetrics) -> CGFloat {
        max(CGFloat(list.keycapMinWidth), ceil(RowTypesetter.lineWidth(line) + CGFloat(list.keycapPadding) * 2))
    }
}
