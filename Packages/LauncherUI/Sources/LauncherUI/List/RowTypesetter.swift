import AppKit
import CoreText

/// One row's text, typeset and placed, relative to the row's top-left corner.
///
/// Built when a row changes and reused while the list scrolls, so a scroll redraw only draws.
struct RowTypeset {
    /// A typeset line and the point where its baseline starts.
    struct PlacedLine {
        var line: CTLine
        var origin: CGPoint
    }

    /// An accessory and its frame. Capsules are drawn behind their text.
    indirect enum Accessory {
        case text(PlacedLine)
        /// The keycaps of one shortcut.
        case group([Accessory])
        case capsule(frame: CGRect, radius: CGFloat, fill: CGColor, text: PlacedLine)
        case image(CGImage, frame: CGRect)
    }

    var iconFrame: CGRect
    var title: PlacedLine
    var titleFrame: CGRect
    var subtitle: PlacedLine?
    var subtitleFrame: CGRect?
    var accessories: [Accessory]
}

/// Typesets rows with Core Text. Fonts and colours come from a resolved theme.
enum RowTypesetter {
    static func typeset(
        _ row: ListRow, width: CGFloat, height: CGFloat, style: RowStyle, emphasizesMatches: Bool,
        theme: ResolvedTheme, scale: CGFloat
    ) -> RowTypeset {
        let metrics = theme.theme.list
        let iconSize = CGFloat(metrics.iconSize)
        let iconFrame = CGRect(
            x: metrics.iconX, y: snap((height - iconSize) / 2, scale), width: iconSize, height: iconSize)
        let textX = CGFloat(metrics.iconX + metrics.iconSize + metrics.iconTextGap)

        // Accessories, laid out from the trailing edge inward.
        let titleFont = theme.titleFont
        let centerBaseline = snap(baseline(centering: titleFont, in: height), scale)
        var right = width - CGFloat(metrics.trailingInset)
        let accessoryLimit = right - width * CGFloat(metrics.maxAccessoryFraction)
        var accessories: [RowTypeset.Accessory] = []
        for accessory in row.accessories.reversed() {
            guard
                let placed = place(
                    accessory, right: right, limit: accessoryLimit, rowHeight: height,
                    baseline: centerBaseline, theme: theme, scale: scale)
            else { break }
            accessories.append(placed.accessory)
            right = placed.minX - CGFloat(metrics.accessorySpacing)
        }
        let textRight = accessories.isEmpty ? right : right + CGFloat(metrics.accessorySpacing - metrics.accessoryGap)
        let available = max(0, textRight - textX)

        let titleLine = CTLineCreateWithAttributedString(
            titleString(row, emphasizesMatches: emphasizesMatches, theme: theme))
        let titleWidth = lineWidth(titleLine)
        let subtitleLine =
            row.subtitle.isEmpty
            ? nil
            : CTLineCreateWithAttributedString(
                attributed(row.subtitle, font: theme.subtitleFont, color: theme.subtitle))

        var title: RowTypeset.PlacedLine
        var subtitle: RowTypeset.PlacedLine?
        switch style {
        case .oneLine:
            let gap = CGFloat(metrics.titleSubtitleGap)
            let fittedTitle = truncate(titleLine, to: available, font: titleFont, color: theme.title)
            title = .init(line: fittedTitle, origin: CGPoint(x: textX, y: centerBaseline))
            if let subtitleLine {
                // The subtitle gives way first; it is dropped once it would be too narrow to read.
                let room = available - titleWidth - gap
                if room >= CGFloat(metrics.minimumSubtitleWidth) {
                    let fitted = truncate(subtitleLine, to: room, font: theme.subtitleFont, color: theme.subtitle)
                    subtitle = .init(line: fitted, origin: CGPoint(x: textX + titleWidth + gap, y: centerBaseline))
                }
            }
        case .twoLine:
            let subtitleFont = theme.subtitleFont
            let titleBlock = CTFontGetAscent(titleFont) + CTFontGetDescent(titleFont)
            let subtitleBlock = CTFontGetAscent(subtitleFont) + CTFontGetDescent(subtitleFont)
            let gap = CGFloat(metrics.twoLineGap)
            let top = (height - titleBlock - (subtitleLine == nil ? 0 : gap + subtitleBlock)) / 2
            let titleBaseline = snap(top + CTFontGetAscent(titleFont), scale)
            title = .init(
                line: truncate(titleLine, to: available, font: titleFont, color: theme.title),
                origin: CGPoint(x: textX, y: titleBaseline))
            if let subtitleLine {
                let subtitleBaseline = snap(
                    titleBaseline + CTFontGetDescent(titleFont) + gap + CTFontGetAscent(subtitleFont), scale)
                subtitle = .init(
                    line: truncate(subtitleLine, to: available, font: subtitleFont, color: theme.subtitle),
                    origin: CGPoint(x: textX, y: subtitleBaseline))
            }
        }
        return RowTypeset(
            iconFrame: iconFrame,
            title: title,
            titleFrame: frame(of: title, font: titleFont),
            subtitle: subtitle,
            subtitleFrame: subtitle.map { frame(of: $0, font: theme.subtitleFont) },
            accessories: accessories
        )
    }

    // MARK: Accessories

    private static func place(
        _ accessory: RowAccessory, right: CGFloat, limit: CGFloat, rowHeight: CGFloat, baseline: CGFloat,
        theme: ResolvedTheme, scale: CGFloat
    ) -> (accessory: RowTypeset.Accessory, minX: CGFloat)? {
        let metrics = theme.theme.list
        let room = right - limit
        guard room > 0 else { return nil }
        switch accessory {
        case .text(let text):
            var line = CTLineCreateWithAttributedString(
                attributed(text, font: theme.accessoryFont, color: theme.accessory))
            // Only text gives way to fit; capsules and icons that do not fit are dropped.
            if lineWidth(line) > room {
                guard room >= CGFloat(metrics.minimumSubtitleWidth) else { return nil }
                line = truncate(line, to: room, font: theme.accessoryFont, color: theme.accessory)
            }
            let x = right - lineWidth(line)
            return (.text(.init(line: line, origin: CGPoint(x: x, y: baseline))), x)
        case .tag(let text, let color):
            let colors = theme.tagColors(color)
            let line = CTLineCreateWithAttributedString(attributed(text, font: theme.tagFont, color: colors.text))
            let height = CGFloat(metrics.tagHeight)
            let capsuleWidth = ceil(lineWidth(line) + CGFloat(metrics.tagPadding) * 2)
            guard capsuleWidth <= room else { return nil }
            let frame = CGRect(
                x: right - capsuleWidth, y: snap((rowHeight - height) / 2, scale), width: capsuleWidth, height: height)
            return (
                .capsule(
                    frame: frame, radius: height / 2, fill: colors.fill,
                    text: centered(line, in: frame, font: theme.tagFont, scale: scale)), frame.minX
            )
        case .keycaps(let keys):
            var placed: [RowTypeset.Accessory] = []
            var x = right
            for key in keys.reversed() {
                let line = CTLineCreateWithAttributedString(
                    attributed(key, font: theme.keycapFont, color: theme.keycapText))
                let height = CGFloat(metrics.keycapHeight)
                let capWidth = max(
                    CGFloat(metrics.keycapMinWidth), ceil(lineWidth(line) + CGFloat(metrics.keycapPadding) * 2))
                let frame = CGRect(
                    x: x - capWidth, y: snap((rowHeight - height) / 2, scale), width: capWidth, height: height)
                guard right - frame.minX <= room else { return nil }
                placed.append(
                    .capsule(
                        frame: frame, radius: CGFloat(metrics.keycapRadius), fill: theme.keycapFill,
                        text: centered(line, in: frame, font: theme.keycapFont, scale: scale)))
                x = frame.minX - CGFloat(metrics.keycapSpacing)
            }
            return placed.isEmpty ? nil : (.group(placed), x + CGFloat(metrics.keycapSpacing))
        case .icon(let image):
            let size = CGFloat(metrics.accessoryIconSize)
            guard size <= room else { return nil }
            let frame = CGRect(x: right - size, y: snap((rowHeight - size) / 2, scale), width: size, height: size)
            return (.image(image, frame: frame), frame.minX)
        }
    }

    // MARK: Text

    private static func titleString(_ row: ListRow, emphasizesMatches: Bool, theme: ResolvedTheme) -> NSAttributedString
    {
        emphasized(
            row.title, highlights: row.titleHighlights, emphasizesMatches: emphasizesMatches, font: theme.titleFont,
            theme: theme)
    }

    /// A title in `font` with its unmatched characters dimmed while a query is active. Weight never
    /// changes, so the text does not shift as matches change.
    static func emphasized(
        _ title: String, highlights: [HighlightRange], emphasizesMatches: Bool, font: CTFont, theme: ResolvedTheme
    ) -> NSAttributedString {
        let dims = emphasizesMatches && !highlights.isEmpty
        let string = NSMutableAttributedString(
            attributedString: attributed(title, font: font, color: dims ? theme.unmatchedTitle : theme.title)
        )
        guard dims else { return string }
        let length = string.length
        for range in highlights {
            let start = min(max(0, range.location), length)
            let end = min(max(start, range.location + range.length), length)
            guard end > start else { continue }
            string.addAttribute(colorKey, value: theme.title, range: NSRange(location: start, length: end - start))
        }
        return string
    }

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [fontKey: font, colorKey: color])
    }

    static func lineWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func truncate(_ line: CTLine, to width: CGFloat, font: CTFont, color: CGColor) -> CTLine {
        guard lineWidth(line) > width else { return line }
        let token = CTLineCreateWithAttributedString(attributed("…", font: font, color: color))
        return CTLineCreateTruncatedLine(line, Double(max(0, width)), .end, token) ?? line
    }

    /// The baseline that centres a font's ascent and descent in `height`.
    static func baseline(centering font: CTFont, in height: CGFloat) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        return (height - ascent - CTFontGetDescent(font)) / 2 + ascent
    }

    /// A line centred in `frame`, snapped to pixels.
    static func centered(_ line: CTLine, in frame: CGRect, font: CTFont, scale: CGFloat)
        -> RowTypeset.PlacedLine
    {
        let x = frame.midX - lineWidth(line) / 2
        return .init(
            line: line,
            origin: CGPoint(x: snap(x, scale), y: snap(frame.minY + baseline(centering: font, in: frame.height), scale))
        )
    }

    private static func frame(of placed: RowTypeset.PlacedLine, font: CTFont) -> CGRect {
        let ascent = CTFontGetAscent(font)
        return CGRect(
            x: placed.origin.x, y: placed.origin.y - ascent, width: lineWidth(placed.line),
            height: ascent + CTFontGetDescent(font))
    }

    static func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
