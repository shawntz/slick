import Kit

/// A color as the feature keeps it: gamma-encoded sRGB components and an alpha.
///
/// A component may lie outside 0...1 when the color lies outside sRGB, such as a color picked on a
/// Display P3 screen or a vivid OKLCH color. This is extended sRGB, the same encoding AppKit uses
/// for `NSColorSpace.extendedSRGB`. The formats show ``clipped``, the nearest color inside sRGB.
nonisolated struct ColorValue: Hashable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    /// From 0, transparent, to 1, opaque.
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A color from 8-bit components, such as a hex color.
    init(bytes red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
    }

    /// How far past 0...1 a component may lie and still count as inside sRGB: half of one 8-bit step.
    /// Every 8-bit format shows such a color exactly, so calling it outside sRGB would be noise.
    static let gamutTolerance = 0.5 / 255

    /// The widest range a stored component may take. Real colors lie well inside it; a value past
    /// it comes from a damaged or hand-edited file.
    static let componentRange = -1.0...2.0

    /// True when every component is a finite number.
    var isFinite: Bool {
        red.isFinite && green.isFinite && blue.isFinite && alpha.isFinite
    }

    /// True when no 8-bit sRGB format can show the color as it is.
    var isOutsideSRGB: Bool {
        let range = -Self.gamutTolerance...(1 + Self.gamutTolerance)
        return !(range.contains(red) && range.contains(green) && range.contains(blue))
    }

    /// The nearest color inside sRGB, by clipping each component to 0...1.
    var clipped: ColorValue {
        ColorValue(red: Self.unit(red), green: Self.unit(green), blue: Self.unit(blue), alpha: Self.unit(alpha))
    }

    /// The color with every component within ``componentRange`` and alpha within 0...1, or nil when
    /// a component is not a number.
    var sanitized: ColorValue? {
        guard isFinite else { return nil }
        let range = Self.componentRange
        func bound(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        return ColorValue(red: bound(red), green: bound(green), blue: bound(blue), alpha: Self.unit(alpha))
    }

    /// The clipped color's components as 8-bit integers.
    var bytes: (red: Int, green: Int, blue: Int, alpha: Int) {
        let color = clipped
        return (Self.byte(color.red), Self.byte(color.green), Self.byte(color.blue), Self.byte(color.alpha))
    }

    /// The clipped color for a swatch.
    var kitColor: KitColor {
        let color = clipped
        return .rgba(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Identifies the color in the history: two picks of the same pixel get the same key. Components
    /// are rounded to four decimal places, finer than any 8-bit step.
    var key: String {
        func part(_ value: Double) -> String {
            guard value.isFinite else { return "nan" }
            return String(Int((min(max(value, -1_000), 1_000) * 10_000).rounded()))
        }
        return part(red) + "," + part(green) + "," + part(blue) + "," + part(alpha)
    }

    /// True when the two colors have the same ``key``, without making the strings: the history
    /// compares a new color with every kept one.
    func matches(_ other: ColorValue) -> Bool {
        func step(_ value: Double) -> Int {
            value.isFinite ? Int((min(max(value, -1_000), 1_000) * 10_000).rounded()) : Int.min
        }
        return step(red) == step(other.red) && step(green) == step(other.green) && step(blue) == step(other.blue)
            && step(alpha) == step(other.alpha)
    }

    /// This color drawn over an opaque background: the result the eye sees, opaque.
    func composited(over background: ColorValue) -> ColorValue {
        let a = Self.unit(alpha)
        func mix(_ top: Double, _ bottom: Double) -> Double { top * a + bottom * (1 - a) }
        return ColorValue(
            red: mix(red, background.red), green: mix(green, background.green), blue: mix(blue, background.blue))
    }

    static let white = ColorValue(red: 1, green: 1, blue: 1)
    static let black = ColorValue(red: 0, green: 0, blue: 0)

    static func unit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func byte(_ value: Double) -> Int {
        Int((unit(value) * 255).rounded())
    }
}
