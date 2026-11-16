import Foundation
import Testing

@testable import ColorTools

/// The conversions against published values: CSS Color 4's examples for HSL and HWB, Python's
/// colorsys for HSL and HSB, Björn Ottosson's Oklab values for the primaries, the CSS Color 4 value
/// of Display P3 red in sRGB, and WebAIM's contrast ratios.
@Suite("Color math", .timeLimit(.minutes(1)))
struct MathTests {
    @Test func hslHsbAndHwbOfRebeccaPurple() throws {
        let purple = try color("#663399")
        let hsl = ColorSpaces.hsl(purple)
        #expect(close(hsl.hue, 270) && close(hsl.saturation, 0.5) && close(hsl.lightness, 0.4))
        let hsb = ColorSpaces.hsb(purple)
        #expect(close(hsb.hue, 270) && close(hsb.saturation, 2.0 / 3) && close(hsb.brightness, 0.6))
        let hwb = ColorSpaces.hwb(purple)
        #expect(close(hwb.hue, 270) && close(hwb.whiteness, 0.2) && close(hwb.blackness, 0.4))
    }

    @Test func skyBlueMatchesColorsys() throws {
        // Python: colorsys.rgb_to_hls and rgb_to_hsv of (135, 206, 235) / 255.
        let sky = try color("#87CEEB")
        let hsl = ColorSpaces.hsl(sky)
        #expect(close(hsl.hue, 197.4) && close(hsl.saturation, 0.714_285_714) && close(hsl.lightness, 0.725_490_196))
        let hsb = ColorSpaces.hsb(sky)
        #expect(close(hsb.saturation, 0.425_531_915) && close(hsb.brightness, 0.921_568_627))
    }

    @Test func primariesAndGraysInEveryModel() throws {
        for (hex, hue) in [("#FF0000", 0.0), ("#00FF00", 120), ("#0000FF", 240), ("#FFFF00", 60), ("#FF00FF", 300)] {
            let value = try color(hex)
            #expect(close(ColorSpaces.hsl(value).hue, hue), "\(hex)")
            #expect(close(ColorSpaces.hsl(value).saturation, 1) && close(ColorSpaces.hsl(value).lightness, 0.5))
            #expect(close(ColorSpaces.hsb(value).brightness, 1))
        }
        let gray = try color("#808080")
        #expect(ColorSpaces.hsl(gray).hue == 0 && ColorSpaces.hsl(gray).saturation == 0)
        #expect(close(ColorSpaces.hsl(gray).lightness, 128.0 / 255))
        #expect(ColorSpaces.hsl(.white).saturation == 0 && ColorSpaces.hsb(.black).saturation == 0)
    }

    @Test func cssExamplesForHslAndHwbGiveTheirColors() throws {
        // CSS Color 4: hsl(120deg 100% 25%) is #008000, and hwb(0 100% 100%) is the gray #808080.
        let green = ColorSpaces.color(HSL(hue: 120, saturation: 1, lightness: 0.25))
        #expect(ColorFormatter().hex(green) == "#008000")
        let gray = ColorSpaces.color(HWB(hue: 0, whiteness: 1, blackness: 1))
        #expect(ColorFormatter().hex(gray) == "#808080")
        let blue = ColorSpaces.color(HWB(hue: 240, whiteness: 0, blackness: 0))
        #expect(ColorFormatter().hex(blue) == "#0000FF")
        let hsb = ColorSpaces.color(HSB(hue: 270, saturation: 2.0 / 3, brightness: 0.6))
        #expect(ColorFormatter().hex(hsb) == "#663399")
    }

    @Test func oklchOfThePrimariesMatchesThePublishedValues() throws {
        let expected: [(String, Double, Double, Double)] = [
            ("#FF0000", 0.627_955, 0.257_683, 29.2339),
            ("#00FF00", 0.866_440, 0.294_827, 142.4953),
            ("#0000FF", 0.452_014, 0.313_214, 264.0520),
            ("#663399", 0.440_272, 0.160_296, 303.3730),
        ]
        for (hex, lightness, chroma, hue) in expected {
            let lch = ColorSpaces.oklch(try color(hex))
            #expect(close(lch.lightness, lightness, 1e-5), "\(hex) L \(lch.lightness)")
            #expect(close(lch.chroma, chroma, 1e-5), "\(hex) C \(lch.chroma)")
            #expect(close(lch.hue, hue, 1e-3), "\(hex) h \(lch.hue)")
        }
        let white = ColorSpaces.oklch(.white)
        #expect(close(white.lightness, 1, 1e-6) && white.chroma < 1e-6 && white.hue == 0)
        let black = ColorSpaces.oklch(.black)
        #expect(black.lightness == 0 && black.chroma == 0)
    }

    @Test func everyModelRoundTrips() {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<2_000 {
            let value = ColorValue(
                red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                blue: .random(in: 0...1, using: &generator))
            let exact = [
                ColorSpaces.color(ColorSpaces.hsl(value)), ColorSpaces.color(ColorSpaces.hsb(value)),
                ColorSpaces.color(ColorSpaces.hwb(value)),
            ]
            for other in exact {
                #expect(close(other.red, value.red, 1e-12) && close(other.green, value.green, 1e-12))
                #expect(close(other.blue, value.blue, 1e-12))
            }
            // The published Oklab matrices have ten decimals, and the inverse is not exact to more
            // than about 2e-6: a five-hundredth of an 8-bit step.
            let lab = ColorSpaces.color(ColorSpaces.oklch(value))
            #expect(close(lab.red, value.red, 5e-6) && close(lab.green, value.green, 5e-6))
            #expect(close(lab.blue, value.blue, 5e-6))
        }
    }

    @Test func oklchRoundTripsKeepEveryByte() {
        for red in stride(from: 0, through: 255, by: 15) {
            for green in stride(from: 0, through: 255, by: 15) {
                for blue in stride(from: 0, through: 255, by: 15) {
                    let value = ColorValue(bytes: red, green, blue)
                    let back = ColorSpaces.color(ColorSpaces.oklch(value))
                    #expect(ColorFormatter().hex(back) == ColorFormatter().hex(value))
                }
            }
        }
    }

    @Test func displayP3RedLiesOutsideSRGB() {
        // CSS Color 4: color(display-p3 1 0 0) is color(srgb 1.0931 -0.2267 -0.1501).
        let red = ColorSpaces.fromDisplayP3(red: 1, green: 0, blue: 0)
        #expect(close(red.red, 1.093_066) && close(red.green, -0.226_742) && close(red.blue, -0.150_135))
        #expect(red.isOutsideSRGB)
        #expect(ColorFormatter().hex(red) == "#FF0000", "formats show the nearest sRGB color")
        let white = ColorSpaces.fromDisplayP3(red: 1, green: 1, blue: 1)
        #expect(close(white.red, 1, 1e-9) && close(white.green, 1, 1e-9) && close(white.blue, 1, 1e-9))
        #expect(!white.isOutsideSRGB)
        // A P3 color inside sRGB stays inside: the sRGB red written in P3.
        let inside = ColorSpaces.fromDisplayP3(red: 0.917_488, green: 0.200_287, blue: 0.138_561)
        #expect(!inside.isOutsideSRGB)
        #expect(ColorFormatter().hex(inside) == "#FF0000")
    }

    @Test func contrastMatchesWebAIM() throws {
        #expect(Contrast(foreground: .black, background: .white).text == "21:1")
        #expect(Contrast(foreground: .white, background: .white).text == "1:1")
        let gray = Contrast(foreground: try color("#767676"), background: .white)
        #expect(gray.text == "4.54:1" && gray.normalText == .aa && gray.largeText == .aaa)
        let lighter = Contrast(foreground: try color("#777777"), background: .white)
        #expect(lighter.text == "4.47:1" && lighter.normalText == .fail && lighter.largeText == .aa)
        let blue = Contrast(foreground: try color("#0000FF"), background: .white)
        #expect(blue.text == "8.59:1" && blue.normalText == .aaa)
        let purple = Contrast(foreground: try color("#663399"), background: .black)
        #expect(purple.text == "2.49:1" && purple.normalText == .fail && purple.largeText == .fail)
        #expect(
            Contrast(foreground: .white, background: .black).ratio
                == Contrast(foreground: .black, background: .white).ratio)
    }

    @Test func contrastBlendsAlphaFirst() throws {
        // Half-transparent black over white is the gray #808080 (rounded), whose contrast is 3.95.
        let half = ColorValue(red: 0, green: 0, blue: 0, alpha: 0.5)
        let blended = Contrast(foreground: half, background: .white)
        let gray = Contrast(foreground: ColorValue(red: 0.5, green: 0.5, blue: 0.5), background: .white)
        #expect(close(blended.ratio, gray.ratio, 1e-12))
        // A transparent background counts as white.
        #expect(
            Contrast(foreground: .black, background: ColorValue(red: 0, green: 0, blue: 0, alpha: 0)).text == "21:1")
    }

    @Test func aRatioJustUnderALevelNeverReadsAsIt() {
        // 4.499 must not show as 4.5 while it fails AA.
        let ratio = Contrast(ratio: 4.499)
        #expect(ratio.text == "4.49:1" && ratio.normalText == .fail)
        #expect(Contrast(ratio: 7).normalText == .aaa && Contrast(ratio: 3).largeText == .aa)
    }

    @Test func decimalsAreLocaleFreeAndTrimmed() {
        #expect(Decimals.string(0.5, places: 3) == "0.5")
        #expect(Decimals.string(40, places: 1) == "40")
        #expect(Decimals.string(-0.0001, places: 2) == "0", "no negative zero")
        #expect(Decimals.string(-1.25, places: 1) == "-1.3")
        #expect(Decimals.string(0.0603, places: 4) == "0.0603")
        #expect(Decimals.string(.nan, places: 2) == "0")
        #expect(Decimals.string(.infinity, places: 2) == "0")
        #expect(Decimals.string(1e30, places: 2) == "1000000000000")
    }
}
