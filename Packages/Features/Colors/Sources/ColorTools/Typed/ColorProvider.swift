import Kit

/// Colors typed in root search: `#663399`, `rgb(102 51 153)`, `color rebeccapurple` and the like
/// show one row at the top with the swatch and the conversions, and `contrast` with two colors shows
/// the WCAG ratio.
///
/// Budget: 100 µs per keystroke on the main thread. ``ColorQuery/kind(of:)`` refuses a query from
/// its first byte, or from at most nine for text that starts like a color, and reads no setting and
/// allocates nothing before it says yes. Only then is the query parsed, up to 200 bytes. Rows are
/// `.never`, so root search keeps nothing of them.
final class ColorProvider: InstantProvider {
    let namespace = ColorsFeature.namespace
    private let actionsMaker: ColorActions
    private let settings: FeatureSettings

    init(actions: ColorActions, settings: FeatureSettings) {
        self.actionsMaker = actions
        self.settings = settings
    }

    func answer(for query: String) -> InstantAnswer? {
        guard let kind = ColorQuery.kind(of: query.utf8), settings[ColorSettings.convertsTypedColors],
            let parsed = ColorQuery.parse(query, kind: kind)
        else { return nil }
        let row: Row
        switch parsed {
        case .color(let color):
            row = TypedRows.color(color, formatter: actionsMaker.formatter, format: actionsMaker.defaultFormat)
        case .contrast(let foreground, let background):
            row = TypedRows.contrast(foreground, on: background, formatter: actionsMaker.formatter)
        }
        return InstantAnswer(rows: [row], claimsTop: true)
    }

    func actions(for row: Row) -> [Action] {
        row.id.key.hasPrefix(TypedRows.contrastPrefix) ? actionsMaker.forContrast(row) : actionsMaker.forTyped(row)
    }
}

/// The rows of typed colors and contrast answers. Pure, so tests and benchmarks call them directly.
nonisolated enum TypedRows {
    static let colorPrefix = "typed."
    static let contrastPrefix = "contrast."
    /// The formats a typed color's subtitle shows after the title's.
    static let subtitleFormats: [ColorFormat] = [.hex, .rgb, .hsl, .oklch]

    /// One color: the default format as the title, three other formats as the subtitle, the swatch
    /// as the icon, and a tag when the color lies outside sRGB.
    static func color(_ color: ColorValue, formatter: ColorFormatter, format: ColorFormat) -> Row {
        let title = formatter.string(color, as: format)
        let others = subtitleFormats.filter { $0 != format }.prefix(3).map { formatter.string(color, as: $0) }
        return Row(
            id: ItemID(ColorsFeature.namespace, colorPrefix + color.key), title: title,
            subtitle: others.joined(separator: "  ·  "), icon: .color(color.kitColor),
            accessories: color.isOutsideSRGB ? [.tag(ColorStrings.outsideSRGB, color: .orange)] : [],
            payload: Payload(TypedPayload(color: color)), completion: title, memory: .never)
    }

    /// A contrast answer: the ratio as the title, the two colors as the subtitle, and the WCAG
    /// verdicts as tags.
    static func contrast(_ foreground: ColorValue, on background: ColorValue, formatter: ColorFormatter) -> Row {
        let contrast = Contrast(foreground: foreground, background: background)
        return Row(
            id: ItemID(ColorsFeature.namespace, contrastPrefix + foreground.key + "/" + background.key),
            title: contrast.text,
            subtitle: ColorStrings.contrastSubtitle(formatter.hex(foreground), formatter.hex(background)),
            icon: .color(foreground.kitColor),
            accessories: [
                .tag(ColorStrings.normalTag(contrast.normalText), color: ColorDetail.tagColor(contrast.normalText)),
                .tag(ColorStrings.largeTag(contrast.largeText), color: ColorDetail.tagColor(contrast.largeText)),
            ],
            payload: Payload(ContrastPayload(foreground: foreground, background: background)), memory: .never)
    }
}
