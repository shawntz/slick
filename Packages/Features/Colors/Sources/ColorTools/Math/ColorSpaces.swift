import Foundation

/// A color in HSL: hue in degrees from 0 up to 360, saturation and lightness from 0 to 1.
nonisolated struct HSL: Hashable, Sendable {
    var hue: Double
    var saturation: Double
    var lightness: Double
}

/// A color in HSB, also called HSV: hue in degrees, saturation and brightness from 0 to 1.
nonisolated struct HSB: Hashable, Sendable {
    var hue: Double
    var saturation: Double
    var brightness: Double
}

/// A color in HWB: hue in degrees, whiteness and blackness from 0 to 1.
nonisolated struct HWB: Hashable, Sendable {
    var hue: Double
    var whiteness: Double
    var blackness: Double
}

/// A color in OKLCH: lightness from 0 to 1, chroma from 0, hue in degrees.
nonisolated struct OKLCH: Hashable, Sendable {
    var lightness: Double
    var chroma: Double
    var hue: Double
}

/// A color in Oklab: lightness and the two opponent axes.
nonisolated struct OKLab: Hashable, Sendable {
    var lightness: Double
    var a: Double
    var b: Double
}

/// Conversions between sRGB and the other color models, and from Display P3 to sRGB.
///
/// HSL, HSB and HWB follow the formulas of CSS Color 4. Oklab and OKLCH use the matrices Björn
/// Ottosson published with Oklab in 2020. Display P3 to sRGB goes through linear light with a
/// matrix derived from the two spaces' primaries and the D65 white point. Every function takes and
/// returns extended sRGB, so colors outside sRGB survive a round trip.
nonisolated enum ColorSpaces {
    // MARK: Transfer function

    /// The sRGB transfer function, from encoded to linear light. Display P3 uses the same one.
    /// Negative values mirror positive ones, as extended sRGB does.
    static func linear(_ encoded: Double) -> Double {
        let magnitude = abs(encoded)
        let value = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return encoded < 0 ? -value : value
    }

    /// From linear light to the sRGB encoding.
    static func encoded(_ linear: Double) -> Double {
        let magnitude = abs(linear)
        let value = magnitude <= 0.003_130_8 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return linear < 0 ? -value : value
    }

    // MARK: Hue

    /// The hue of a color in degrees from 0 up to 360, and the largest and smallest components.
    /// Gray has hue 0, as CSS Color 4 serializes a powerless hue.
    private static func hue(_ color: ColorValue) -> (hue: Double, maximum: Double, minimum: Double) {
        let r = color.red
        let g = color.green
        let b = color.blue
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        guard delta > 0 else { return (0, maximum, minimum) }
        let sector: Double
        if maximum == r {
            sector = (g - b) / delta + (g < b ? 6 : 0)
        } else if maximum == g {
            sector = (b - r) / delta + 2
        } else {
            sector = (r - g) / delta + 4
        }
        return (normalizedHue(sector * 60), maximum, minimum)
    }

    /// A hue in degrees moved into 0 up to 360.
    static func normalizedHue(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let value = degrees.truncatingRemainder(dividingBy: 360)
        let positive = value < 0 ? value + 360 : value
        return positive >= 360 ? 0 : positive
    }

    // MARK: HSL

    static func hsl(_ color: ColorValue) -> HSL {
        let (hue, maximum, minimum) = hue(color)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        let saturation: Double
        if delta == 0 || lightness <= 0 || lightness >= 1 {
            saturation = 0
        } else {
            saturation = delta / (1 - abs(2 * lightness - 1))
        }
        return HSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    static func color(_ hsl: HSL, alpha: Double = 1) -> ColorValue {
        let hue = normalizedHue(hsl.hue)
        let s = hsl.saturation
        let l = hsl.lightness
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return ColorValue(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
    }

    // MARK: HSB

    static func hsb(_ color: ColorValue) -> HSB {
        let (hue, maximum, minimum) = hue(color)
        let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
        return HSB(hue: hue, saturation: saturation, brightness: maximum)
    }

    static func color(_ hsb: HSB, alpha: Double = 1) -> ColorValue {
        let hue = normalizedHue(hsb.hue)
        let s = hsb.saturation
        let v = hsb.brightness
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 60).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        return ColorValue(red: channel(5), green: channel(3), blue: channel(1), alpha: alpha)
    }

    // MARK: HWB

    static func hwb(_ color: ColorValue) -> HWB {
        let (hue, maximum, minimum) = hue(color)
        return HWB(hue: hue, whiteness: minimum, blackness: 1 - maximum)
    }

    /// When whiteness and blackness add up to 1 or more, the color is the gray they make, as CSS
    /// Color 4 says.
    static func color(_ hwb: HWB, alpha: Double = 1) -> ColorValue {
        let white = hwb.whiteness
        let black = hwb.blackness
        if white + black >= 1 {
            let gray = white / (white + black)
            return ColorValue(red: gray, green: gray, blue: gray, alpha: alpha)
        }
        let pure = color(HSL(hue: hwb.hue, saturation: 1, lightness: 0.5))
        func channel(_ value: Double) -> Double { value * (1 - white - black) + white }
        return ColorValue(red: channel(pure.red), green: channel(pure.green), blue: channel(pure.blue), alpha: alpha)
    }

    // MARK: Oklab and OKLCH

    static func oklab(_ color: ColorValue) -> OKLab {
        let r = linear(color.red)
        let g = linear(color.green)
        let b = linear(color.blue)
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return OKLab(
            lightness: 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
            a: 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
            b: 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s)
    }

    static func color(_ lab: OKLab, alpha: Double = 1) -> ColorValue {
        let l = lab.lightness + 0.396_337_777_4 * lab.a + 0.215_803_757_3 * lab.b
        let m = lab.lightness - 0.105_561_345_8 * lab.a - 0.063_854_172_8 * lab.b
        let s = lab.lightness - 0.089_484_177_5 * lab.a - 1.291_485_548_0 * lab.b
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s
        return ColorValue(
            red: encoded(4.076_741_662_1 * l3 - 3.307_711_591_3 * m3 + 0.230_969_929_2 * s3),
            green: encoded(-1.268_438_004_6 * l3 + 2.609_757_401_1 * m3 - 0.341_319_396_5 * s3),
            blue: encoded(-0.004_196_086_3 * l3 - 0.703_418_614_7 * m3 + 1.707_614_701_0 * s3),
            alpha: alpha)
    }

    /// Below this chroma the hue means nothing, so it is 0, as for gray in HSL.
    static let achromaticChroma = 0.000_05

    static func oklch(_ color: ColorValue) -> OKLCH {
        let lab = oklab(color)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let hue = chroma < achromaticChroma ? 0 : normalizedHue(atan2(lab.b, lab.a) * 180 / .pi)
        return OKLCH(lightness: lab.lightness, chroma: chroma, hue: hue)
    }

    static func color(_ lch: OKLCH, alpha: Double = 1) -> ColorValue {
        let radians = normalizedHue(lch.hue) * .pi / 180
        return color(
            OKLab(lightness: lch.lightness, a: lch.chroma * cos(radians), b: lch.chroma * sin(radians)), alpha: alpha)
    }

    // MARK: Display P3

    /// Linear Display P3 to linear sRGB, from the primaries of both spaces and the D65 white point,
    /// computed in exact fractions.
    static let displayP3ToSRGB: [[Double]] = [
        [1.224_940_176_280_559_8, -0.224_940_176_280_559_96, 0],
        [-0.042_056_954_709_688_16, 1.042_056_954_709_688, 0],
        [-0.019_637_554_590_334_432, -0.078_636_045_550_631_89, 1.098_273_600_140_966_3],
    ]

    /// A Display P3 color, gamma encoded, as extended sRGB.
    static func fromDisplayP3(red: Double, green: Double, blue: Double, alpha: Double = 1) -> ColorValue {
        let input = [linear(red), linear(green), linear(blue)]
        let rows = displayP3ToSRGB.map { row in
            encoded(row[0] * input[0] + row[1] * input[1] + row[2] * input[2])
        }
        return ColorValue(red: rows[0], green: rows[1], blue: rows[2], alpha: alpha)
    }
}
