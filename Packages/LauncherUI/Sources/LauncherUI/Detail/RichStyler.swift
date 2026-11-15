import AppKit

/// Turns rich text and terminal output into attributed text for the detail pane, within the
/// theme's rules: fonts at the theme's body size scaled within limits, and colours moved toward
/// the text colour until they reach 4.5:1 over the glass.
@MainActor
struct RichStyler {
    let theme: ResolvedTheme
    /// Colours already made legible, by what was asked for. Terminal output repeats a few colours.
    private var colors: [String: NSColor] = [:]

    init(theme: ResolvedTheme) {
        self.theme = theme
    }

    private var style: ResolvedDetailStyle { theme.detail }

    private func paragraphStyle() -> NSParagraphStyle {
        let metrics = theme.theme.detail
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(metrics.lineSpacing)
        paragraph.paragraphSpacing = CGFloat(metrics.paragraphSpacing)
        return paragraph
    }

    // MARK: Rich text

    func render(_ rich: RichText) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = paragraphStyle()
        var cache = self
        for run in rich.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: run), .paragraphStyle: paragraph,
                .foregroundColor: run.color.map { cache.legible($0) } ?? style.text,
            ]
            if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = style.link
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func font(for run: RichText.Run) -> NSFont {
        let scale = min(RichText.maximumScale, max(RichText.minimumScale, run.sizeScale))
        let body = run.isMonospaced ? style.monospacedFont : style.textFont
        let size = (body.pointSize * CGFloat(scale)).rounded()
        var font = NSFont(descriptor: body.fontDescriptor, size: size) ?? body
        let manager = NSFontManager.shared
        if !run.isMonospaced, let family = run.fontFamily,
            let named = manager.font(withFamily: family, traits: [], weight: 5, size: size)
        {
            font = named
        }
        if run.isBold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if run.isItalic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private mutating func legible(_ color: ThemeColor, minimumRatio: Double = 4.5) -> NSColor {
        let key = "\(color)|\(minimumRatio)"
        if let cached = colors[key] { return cached }
        let resolved = NSColor(cgColor: theme.legible(color.cgColor(in: theme.appearance), minimumRatio: minimumRatio))
        let made = resolved ?? style.text
        colors[key] = made
        return made
    }

    // MARK: Terminal output

    /// One chunk of plain or monospaced text, with its ANSI colours drawn. `parser` carries the
    /// style and any cut escape sequence from the chunk before.
    mutating func terminal(_ chunk: String, monospaced: Bool, parser: inout ANSIParser) -> NSAttributedString {
        let base = monospaced ? style.monospacedFont : style.textFont
        let paragraph = paragraphStyle()
        if parser.passesThrough(chunk) {
            return NSAttributedString(
                string: chunk, attributes: [.font: base, .foregroundColor: style.text, .paragraphStyle: paragraph])
        }
        let result = NSMutableAttributedString()
        let manager = NSFontManager.shared
        for run in parser.parse(chunk) {
            let ansi = run.style
            var font = base
            if ansi.isBold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if ansi.isItalic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            // Dim text is held to the secondary target, 3:1.
            let ratio = ansi.isDim ? 3.0 : 4.5
            var foreground = ansi.foreground.map { color(for: $0, minimumRatio: ratio) }
            if foreground == nil, ansi.isDim { foreground = style.secondaryText }
            var background = ansi.background.map { color(for: $0, minimumRatio: 1) }
            if ansi.isInverse { background = foreground ?? style.text }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: foreground ?? style.text,
            ]
            // A full background fill would decide the text's contrast instead of the theme, so it
            // is drawn as a faint wash of its colour.
            if let background { attributes[.backgroundColor] = background.withAlphaComponent(0.22) }
            if ansi.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if ansi.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private mutating func color(for ansi: ANSIColor, minimumRatio: Double) -> NSColor {
        if let system = ansi.system { return legible(ThemeColor(system), minimumRatio: minimumRatio) }
        guard let rgb = ansi.srgb else { return style.text }
        return legible(ThemeColor(red: rgb.red, green: rgb.green, blue: rgb.blue), minimumRatio: minimumRatio)
    }
}
