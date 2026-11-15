/// Reads digits and signs typed in other forms as the ASCII the engine knows: full-width forms, as
/// a Japanese or Chinese input method types them, the ideographic space, and the decimal digits of
/// every script, such as Arabic-Indic or Devanagari digits.
///
/// Runs inside the keystroke. An ASCII query costs one pass over its bytes and nothing else. A
/// query with other characters costs one more pass over its scalars. A new string is made only
/// when the query holds a digit to fold, since without one it cannot be math the engine reads, so
/// text in other scripts is still turned away without an allocation.
nonisolated enum QueryFolding {
    /// The query with foldable characters replaced, or nil when it has no digit to fold.
    static func folded(_ query: String) -> String? {
        guard query.utf8.contains(where: { $0 >= 0x80 }) else { return nil }
        guard query.unicodeScalars.contains(where: { replacement(for: $0).map(isDigit) == true }) else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in query.unicodeScalars {
            scalars.append(replacement(for: scalar) ?? scalar)
        }
        return String(scalars)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    /// The ASCII scalar that stands for `scalar`, or nil to keep it.
    static func replacement(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        guard value >= 0x80 else { return nil }
        // Full-width ASCII, U+FF01 to U+FF5E, sits 0xFEE0 above ASCII.
        if (0xFF01...0xFF5E).contains(value) { return Unicode.Scalar(value - 0xFEE0) }
        switch value {
        case 0x3000: return " "
        // Arabic decimal and thousands separators.
        case 0x066B: return "."
        case 0x066C: return ","
        default: break
        }
        guard scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue,
            digit >= 0, digit <= 9
        else { return nil }
        return Unicode.Scalar(UInt8(48 + Int(digit)))
    }
}
