import Foundation

/// The arithmetic of the volume commands, apart from any device.
nonisolated enum VolumeLevel {
    /// Reads what the user typed for Set Volume: a whole or decimal number from 0 to 100, with or
    /// without a percent sign, such as "40", "40%" or "37.5". Digits of any script count, so
    /// full-width and Arabic-Indic digits work as typed. Returns the level from 0 to 1, or nil for
    /// anything else, including numbers out of range.
    static func parse(_ text: String) -> Double? {
        // A number this long is not a volume, and the limit keeps the work small.
        guard text.unicodeScalars.count <= 64 else { return nil }
        var digits = asciiDigits(text).trimmingCharacters(in: .whitespaces)
        if digits.hasSuffix("%") {
            digits.removeLast()
            digits = digits.trimmingCharacters(in: .whitespaces)
        }
        digits = digits.replacingOccurrences(of: ",", with: ".")
        let allowed = Set("0123456789.")
        guard !digits.isEmpty, digits.allSatisfy(allowed.contains), digits.filter({ $0 == "." }).count <= 1,
            digits.contains(where: \.isNumber), let value = Double(digits), (0...100).contains(value)
        else {
            return nil
        }
        return value / 100
    }

    /// The text with every decimal digit written as an ASCII digit, full-width or Arabic percent
    /// signs and decimal separators written as their ASCII forms, and invisible format marks left
    /// out. Other characters stay.
    private static func asciiDigits(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // Invisible marks, such as the ones that set the direction of right-to-left text.
            if scalar.properties.generalCategory == .format { continue }
            if scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue,
                let digit = Unicode.Scalar(0x30 + UInt32(value))
            {
                result.append(digit)
            } else {
                result.append(separators[scalar] ?? scalar)
            }
        }
        return String(result)
    }

    private static let separators: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{FF05}": "%", "\u{066A}": "%", "\u{FF0E}": ".", "\u{FF0C}": ",", "\u{066B}": ".",
    ]

    /// The next level up or down on a grid that splits the range into `divisions` steps. A level
    /// between two grid points moves to the nearer one in that direction, so presses always land on
    /// the grid, as the volume keys do. Dividing by a whole number keeps grid points exact, so 6
    /// tenths is exactly 0.6.
    static func stepped(_ level: Double, divisions: Int, up: Bool) -> Double {
        guard divisions > 0 else { return level }
        let count = Double(divisions)
        // The tolerance keeps a level that is on the grid, give or take rounding, on its point.
        let position = level * count
        let next = up ? (position + 1e-6).rounded(.down) + 1 : (position - 1e-6).rounded(.up) - 1
        return min(count, max(0, next)) / count
    }

    /// The level as a whole percentage, as the HUD shows it.
    static func percent(_ level: Double) -> Int {
        Int((min(1, max(0, level)) * 100).rounded())
    }
}
