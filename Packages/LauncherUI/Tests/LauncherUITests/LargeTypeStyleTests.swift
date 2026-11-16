import AppKit
import Testing

@testable import LauncherUI

/// Large Type's backing follows the theme and stays dark, so its white text reads over any screen.
@Suite("Large Type: style", .timeLimit(.minutes(1)))
@MainActor struct LargeTypeStyleTests {
    private func components(_ color: CGColor) -> [Double] {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return (color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components ?? []).map(Double.init)
    }

    /// The contrast of white text over the backing laid over a white or a black screen.
    private func contrast(_ style: LargeTypeStyle, over backdrop: Double) -> Double {
        let fill = components(style.fill)
        let alpha = fill[3]
        let mixed = (0..<3).map { fill[$0] * alpha + backdrop * (1 - alpha) }
        let luminance = LegibleColor.luminance(red: mixed[0], green: mixed[1], blue: mixed[2])
        return LegibleColor.ratio(1, luminance)
    }

    @Test func theStandardThemeGivesADarkRoundedBackingAndWhiteText() {
        _ = NSApplication.shared
        let style = LargeTypeStyle(theme: .standard, accessibility: DisplayAccessibility())
        let fill = components(style.fill)
        #expect(fill[3] >= LargeTypeStyle.minimumAlpha)
        #expect(LegibleColor.luminance(red: fill[0], green: fill[1], blue: fill[2]) <= LargeTypeStyle.maximumLuminance)
        #expect(components(style.text) == [1, 1, 1, 1])
        #expect(style.cornerRadius == CGFloat(Theme.standard.panel.cornerRadius))
        #expect(style.font.weight == .semibold)
        #expect(contrast(style, over: 1) >= 7, "over a white screen")
        #expect(contrast(style, over: 0) >= 7, "over a black screen")
    }

    @Test func itFollowsTheThemesCornerAndDesign() {
        _ = NSApplication.shared
        var theme = Theme.standard
        theme.panel.cornerRadius = 12
        theme.fonts.title.design = .rounded
        let style = LargeTypeStyle(theme: theme, accessibility: DisplayAccessibility())
        #expect(style.cornerRadius == 12)
        #expect(style.font.design == .rounded)
    }

    @Test func aLightTintGivesWayToBlack() {
        _ = NSApplication.shared
        var theme = Theme.standard
        theme.dark.hudTint = ThemeColor(.white, alpha: 0.9)
        let style = LargeTypeStyle(theme: theme, accessibility: DisplayAccessibility())
        let fill = components(style.fill)
        #expect(Array(fill.prefix(3)) == [0, 0, 0])
        #expect(contrast(style, over: 1) >= 7)
    }

    @Test(arguments: [
        DisplayAccessibility(reduceTransparency: true), DisplayAccessibility(increaseContrast: true),
    ])
    func reducedTransparencyOrMoreContrastMakesItOpaque(accessibility: DisplayAccessibility) {
        _ = NSApplication.shared
        let style = LargeTypeStyle(theme: .standard, accessibility: accessibility)
        #expect(components(style.fill)[3] == 1)
    }

    @Test func theViewTakesTheLayoutsSizeAndTheStylesBacking() {
        _ = NSApplication.shared
        let style = LargeTypeStyle(theme: .standard, accessibility: DisplayAccessibility())
        let layout = LargeTypeLayout.make(
            "482 913", screen: CGRect(x: 0, y: 0, width: 1440, height: 875), font: style.font)
        let view = LargeTypeView()
        view.apply(layout, style: style)
        #expect(view.frame.size == layout.frame.size)
        #expect(view.layer?.cornerRadius == style.cornerRadius)
        #expect(view.layer?.backgroundColor == style.fill)
    }
}
