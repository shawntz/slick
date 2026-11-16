import AppKit

/// How Large Type looks: white text on a dark rounded backing that follows the theme.
///
/// The backing takes the theme's dark HUD tint and corner radius, and the text takes the design of
/// the theme's title font. The backing stays dark whatever the theme says, because the text is
/// white and must read over any screen: a tint lighter than the limit is replaced with black, and
/// the tint is made at least ``minimumAlpha`` opaque, fully opaque under Reduce Transparency or
/// Increase Contrast.
public struct LargeTypeStyle {
    /// The least opacity of the backing.
    public static let minimumAlpha = 0.85
    /// The most relative luminance the backing's tint may have before black replaces it.
    public static let maximumLuminance = 0.18

    /// The backing's colour, in sRGB.
    public let fill: CGColor
    /// The text's colour.
    public let text: CGColor
    public let cornerRadius: CGFloat
    /// The font's weight and design. Its size comes from ``LargeTypeLayout``.
    public let font: ThemeFont

    public init(theme: Theme, accessibility: DisplayAccessibility) {
        let dark = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        let tint = theme.dark.hudTint.cgColor(in: dark)
        var components = (red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = tint.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
            converted.count >= 4
        {
            components = (Double(converted[0]), Double(converted[1]), Double(converted[2]), Double(converted[3]))
        }
        let luminance = LegibleColor.luminance(red: components.red, green: components.green, blue: components.blue)
        if luminance > Self.maximumLuminance { components = (0, 0, 0, components.alpha) }
        let opaque = accessibility.reduceTransparency || accessibility.increaseContrast
        let alpha = opaque ? 1 : max(Self.minimumAlpha, components.alpha)
        fill = CGColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: alpha)
        text = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        cornerRadius = CGFloat(theme.panel.cornerRadius)
        let title = theme.fonts.title
        font = ThemeFont(size: title.size, weight: .semibold, design: title.design)
    }
}
