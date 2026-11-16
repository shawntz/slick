import AppKit
import Testing

@testable import LauncherUI

/// In light mode every built-in theme keeps the white glass, so its lens carries its colour. These
/// tests stand in for the capture matrix between captures: a fill lens is composited over white
/// glass and over the darkest light glass the matrix found behind titles, and a glass lens's tint
/// is mixed over white at the strength measured in the matrix.
@Suite(.timeLimit(.minutes(1)))
struct LightLensTests {
    typealias RGB = (red: Double, green: Double, blue: Double)

    /// A glass lens over white glass showed its tint at about 1.2 times the tint's alpha.
    static let glassLensStrength = 1.2
    /// macOS's default accent, which Standard takes from the system.
    static let systemBlue = ThemeColor(red: 0, green: 0x7A / 255, blue: 1)

    static func components(_ color: ThemeColor) -> (RGB, Double)? {
        switch color.source {
        case .srgb(let red, let green, let blue): return ((red, green, blue), color.alpha)
        case .system(.black): return ((0, 0, 0), color.alpha)
        case .system(.white): return ((1, 1, 1), color.alpha)
        default: return nil
        }
    }

    static func over(_ top: RGB, _ alpha: Double, _ bottom: RGB) -> RGB {
        (
            top.red * alpha + bottom.red * (1 - alpha), top.green * alpha + bottom.green * (1 - alpha),
            top.blue * alpha + bottom.blue * (1 - alpha)
        )
    }

    static func lab(_ color: RGB) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(color.red), linear(color.green), linear(color.blue))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// The light lens of `theme` over white glass.
    static func lensOverWhite(_ theme: Theme) -> RGB? {
        let white: RGB = (1, 1, 1)
        switch theme.lens.style {
        case .fill:
            guard let (color, alpha) = components(theme.light.lensFill) else { return nil }
            return over(color, alpha, white)
        case .glass:
            let tint = theme.light.lensGlassTint.source == .system(.accent) ? systemBlue : theme.light.lensGlassTint
            guard let (color, _) = components(tint) else { return nil }
            return over(color, min(1, theme.light.lensGlassTint.alpha * glassLensStrength), white)
        }
    }

    /// Among the themes that share Standard's slab and glass, the lens is what tells them apart.
    /// Beam and Clear differ in the glass itself.
    @Test func everyRecolourLensReadsAsItsOwnInLightMode() throws {
        var lenses: [(String, (Double, Double, Double))] = []
        for named in ThemeStore.builtInThemes
        where named.theme.panel.layout == .single && named.theme.panel.glassStyle == .regular {
            let lens = try #require(Self.lensOverWhite(named.theme), "\(named.name)")
            lenses.append((named.name, Self.lab(lens)))
        }
        for i in lenses.indices {
            for j in lenses.indices where j > i {
                let (a, b) = (lenses[i].1, lenses[j].1)
                let distance = sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
                #expect(distance >= 15, "\(lenses[i].0) and \(lenses[j].0) are \(distance) apart")
            }
        }
    }

    @Test func fillLensesKeepTitlesReadableOverTheDarkestLightGlass() throws {
        // A grey of the reference luminance stands for the darkest light glass behind titles.
        let grey = pow(LegibleColor.lightReferenceLuminance, 1 / 2.2)
        let glass: RGB = (grey, grey, grey)
        for named in ThemeStore.builtInThemes where named.theme.lens.style == .fill {
            let (color, alpha) = try #require(Self.components(named.theme.light.lensFill), "\(named.name)")
            let lens = Self.over(color, alpha, glass)
            // The system's label is black at 0.8471 in light mode; a theme may ask for pure black.
            let titleColor = named.theme.light.title
            let titleAlpha = titleColor.alpha * (titleColor.source == .system(.label) ? 0.8471 : 1)
            let title = Self.over((0, 0, 0), titleAlpha, lens)
            let ratio = LegibleColor.ratio(
                LegibleColor.luminance(red: title.red, green: title.green, blue: title.blue),
                LegibleColor.luminance(red: lens.red, green: lens.green, blue: lens.blue))
            #expect(ratio >= 4.5, "\(named.name): \(ratio)")
        }
    }

    @Test func darkModeLensesAreUnchanged() {
        #expect(Theme.graphite.dark.lensFill == Theme.standard.dark.lensFill)
        #expect(Theme.ember.dark.lensFill.description == "#B5470F@0.24")
        #expect(Theme.ocean.dark.lensGlassTint.description == "#0B6E8A@0.3")
        #expect(Theme.violet.light.lensGlassTint.description.hasPrefix("#A522FC@"))
        #expect(Theme.standard.light.lensGlassTint.source == .system(.accent))
    }
}
