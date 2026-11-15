/// A color a feature asks for. Semantic colors follow the theme and the appearance; RGBA colors are
/// shown as given, for content such as a copied color value.
public enum KitColor: Hashable, Sendable, Codable {
    /// A named color from the theme.
    case semantic(SemanticColor)
    /// An exact color in sRGB, each component from 0 to 1.
    case rgba(red: Double, green: Double, blue: Double, alpha: Double)

    public static let accent = KitColor.semantic(.accent)
    public static let primary = KitColor.semantic(.primary)
    public static let secondary = KitColor.semantic(.secondary)
    public static let red = KitColor.semantic(.red)
    public static let orange = KitColor.semantic(.orange)
    public static let yellow = KitColor.semantic(.yellow)
    public static let green = KitColor.semantic(.green)
    public static let blue = KitColor.semantic(.blue)
    public static let purple = KitColor.semantic(.purple)
    public static let pink = KitColor.semantic(.pink)
    public static let gray = KitColor.semantic(.gray)

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, with or without the `#`.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard [3, 4, 6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        let short = digits.count <= 4
        let hasAlpha = digits.count == 4 || digits.count == 8
        let bits = short ? 4 : 8
        let count = hasAlpha ? 4 : 3
        let maximum = Double((1 << bits) - 1)
        var components: [Double] = []
        for index in 0..<count {
            let shift = UInt64((count - 1 - index) * bits)
            components.append(Double((value >> shift) & UInt64((1 << bits) - 1)) / maximum)
        }
        self = .rgba(red: components[0], green: components[1], blue: components[2], alpha: hasAlpha ? components[3] : 1)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when alpha is below 1. Nil for semantic colors.
    public var hexString: String? {
        guard case .rgba(let red, let green, let blue, let alpha) = self else { return nil }
        func byte(_ component: Double) -> String {
            let value = Int((min(max(component, 0), 1) * 255).rounded())
            let digits = String(value, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }
}

/// The theme's named colors. The host maps each to a color that meets the contrast rules over glass.
public enum SemanticColor: String, Hashable, Sendable, Codable, CaseIterable {
    case accent, primary, secondary, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown,
        gray
}
