import AppKit

/// Moves a content colour, such as a run of rich text or an ANSI colour, toward the theme's text
/// colour until it reaches a contrast ratio over the glass, so colours a feature asks for still
/// meet glass rule 5.
///
/// Text in the detail pane is drawn without vibrancy, so the glass behind it decides how readable
/// it is. The reference background stands for the hardest glass the capture matrix found behind
/// titles: the lightest in dark mode and the darkest in light mode, over the busy, white and dark
/// backdrops. Pure white over the dark reference and pure black over the light one reach about
/// 5.8:1 and 5.5:1, a little above the least title contrast the matrix measured.
nonisolated public enum LegibleColor {
    /// Relative luminance of the reference glass in dark mode.
    public static let darkReferenceLuminance = 0.13
    /// Relative luminance of the reference glass in light mode.
    public static let lightReferenceLuminance = 0.22

    /// WCAG relative luminance of an sRGB colour with components from 0 to 1.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.04045 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio between two luminances, from 1 to 21.
    public static func ratio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `color` mixed toward `text` by the least amount that reaches `minimumRatio` against a
    /// background of luminance `reference`, in steps of 1/32. When `text` itself falls short, the
    /// goal is what `text` reaches. Components are sRGB from 0 to 1.
    public static func adjust(
        _ color: (red: Double, green: Double, blue: Double), toward text: (red: Double, green: Double, blue: Double),
        reference: Double, minimumRatio: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let textRatio = ratio(luminance(red: text.red, green: text.green, blue: text.blue), reference)
        let goal = min(minimumRatio, textRatio)
        for step in 0...32 {
            let amount = Double(step) / 32
            let mixed = (
                red: color.red + (text.red - color.red) * amount,
                green: color.green + (text.green - color.green) * amount,
                blue: color.blue + (text.blue - color.blue) * amount
            )
            if ratio(luminance(red: mixed.red, green: mixed.green, blue: mixed.blue), reference) >= goal - 0.0001 {
                return mixed
            }
        }
        return text
    }
}

extension ResolvedTheme {
    /// `color` moved toward the title colour until it reaches `minimumRatio` over the glass of this
    /// appearance. Opaque; its alpha is dropped, because faint text cannot be held to a ratio.
    public func legible(_ color: CGColor, minimumRatio: Double = 4.5) -> CGColor {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let source = color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            let text = title.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            source.count >= 3, text.count >= 3
        else { return title }
        let reference = isDark ? LegibleColor.darkReferenceLuminance : LegibleColor.lightReferenceLuminance
        let adjusted = LegibleColor.adjust(
            (Double(source[0]), Double(source[1]), Double(source[2])),
            toward: (Double(text[0]), Double(text[1]), Double(text[2])), reference: reference,
            minimumRatio: minimumRatio)
        return CGColor(srgbRed: adjusted.red, green: adjusted.green, blue: adjusted.blue, alpha: 1)
    }
}
