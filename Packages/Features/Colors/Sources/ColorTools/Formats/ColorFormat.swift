import Kit

/// The ways the feature writes a color.
nonisolated enum ColorFormat: String, CaseIterable, Hashable, Sendable, SettingValue {
    /// `#663399`, or `#66339980` with alpha.
    case hex
    /// `rgb(102 51 153)`.
    case rgb
    /// `hsl(270 50% 40%)`.
    case hsl
    /// `hsb(270 66.7% 60%)`, the model of the macOS color panel and design apps.
    case hsb
    /// `hwb(270 20% 40%)`.
    case hwb
    /// `oklch(44.03% 0.1603 303.37)`.
    case oklch
    /// `Color(red: 0.4, green: 0.2, blue: 0.6)`.
    case swiftUI
    /// `NSColor(srgbRed: 0.4, green: 0.2, blue: 0.6, alpha: 1)`.
    case appKit
    /// `--color-663399: #663399;`, named after the color's name when it has one.
    case cssVariable
}

/// Uppercase or lowercase hex digits.
nonisolated enum HexCase: String, CaseIterable, Hashable, Sendable, SettingValue {
    case uppercase
    case lowercase
}

/// Writes colors in every format. Every format shows the color clipped to sRGB; see
/// ``ColorValue/clipped``. Numbers always use a point for decimals, as code does.
nonisolated struct ColorFormatter: Hashable, Sendable {
    var hexCase: HexCase = .uppercase

    /// The color in one format. `name` names the CSS variable; other formats ignore it.
    func string(_ color: ColorValue, as format: ColorFormat, name: String? = nil) -> String {
        let clipped = color.clipped
        switch format {
        case .hex:
            return hex(color)
        case .rgb:
            let bytes = color.bytes
            return "rgb(\(bytes.red) \(bytes.green) \(bytes.blue)\(cssAlpha(clipped)))"
        case .hsl:
            let hsl = ColorSpaces.hsl(clipped)
            return "hsl(\(degrees(hsl.hue)) \(percent(hsl.saturation)) \(percent(hsl.lightness))\(cssAlpha(clipped)))"
        case .hsb:
            let hsb = ColorSpaces.hsb(clipped)
            return "hsb(\(degrees(hsb.hue)) \(percent(hsb.saturation)) \(percent(hsb.brightness))\(cssAlpha(clipped)))"
        case .hwb:
            let hwb = ColorSpaces.hwb(clipped)
            return "hwb(\(degrees(hwb.hue)) \(percent(hwb.whiteness)) \(percent(hwb.blackness))\(cssAlpha(clipped)))"
        case .oklch:
            let lch = ColorSpaces.oklch(clipped)
            let lightness = Decimals.string(lch.lightness * 100, places: 2) + "%"
            let chroma = Decimals.string(lch.chroma, places: 4)
            let hue = degrees(lch.hue, places: 2)
            return "oklch(\(lightness) \(chroma) \(hue)\(cssAlpha(clipped)))"
        case .swiftUI:
            let opacity = clipped.alpha < 1 ? ", opacity: " + unit(clipped.alpha) : ""
            return
                "Color(red: \(unit(clipped.red)), green: \(unit(clipped.green)), blue: \(unit(clipped.blue))\(opacity))"
        case .appKit:
            return "NSColor(srgbRed: \(unit(clipped.red)), green: \(unit(clipped.green)), blue: "
                + "\(unit(clipped.blue)), alpha: \(unit(clipped.alpha)))"
        case .cssVariable:
            return "--\(Self.variableName(for: color, name: name)): \(hex(color));"
        }
    }

    /// `#RRGGBB`, with two more digits for alpha below 1.
    func hex(_ color: ColorValue) -> String {
        let bytes = color.bytes
        var text = "#" + Self.byte(bytes.red) + Self.byte(bytes.green) + Self.byte(bytes.blue)
        if bytes.alpha < 255 { text += Self.byte(bytes.alpha) }
        return hexCase == .uppercase ? text.uppercased() : text
    }

    /// A CSS custom property name: the color's name in lowercase words joined by hyphens, or
    /// `color-` and the hex digits for a color without a name. Only ASCII letters and digits are
    /// kept, so the name is valid in any style sheet.
    static func variableName(for color: ColorValue, name: String?) -> String {
        var slug = ""
        for scalar in (name ?? "").lowercased().unicodeScalars {
            if scalar.isASCII, ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
            if slug.utf8.count >= 40 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty {
            let bytes = color.bytes
            slug = "color-" + byte(bytes.red) + byte(bytes.green) + byte(bytes.blue)
            if bytes.alpha < 255 { slug += byte(bytes.alpha) }
        } else if let first = slug.unicodeScalars.first, ("0"..."9").contains(first) {
            slug = "color-" + slug
        }
        return slug
    }

    /// " / 0.5" for a color with alpha, nothing for an opaque one.
    private func cssAlpha(_ color: ColorValue) -> String {
        color.alpha < 1 ? " / " + Decimals.string(color.alpha, places: 3) : ""
    }

    private func degrees(_ value: Double, places: Int = 1) -> String {
        let text = Decimals.string(value, places: places)
        // 359.96 rounds to 360, which is 0.
        return text == "360" ? "0" : text
    }

    private func percent(_ value: Double) -> String {
        Decimals.string(value * 100, places: 1) + "%"
    }

    private func unit(_ value: Double) -> String {
        Decimals.string(value, places: 3)
    }

    private static func byte(_ value: Int) -> String {
        let digits = String(min(max(value, 0), 255), radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }
}
