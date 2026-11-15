/// Rounds the number at the start of an answer to at most a number of decimal places, on the text
/// itself, so no digit is lost to binary floating point.
///
/// The engine writes numbers with the context's separators: an optional minus, integer digits
/// grouped by threes, then the decimal separator and the fraction, then perhaps a unit or a percent
/// sign. Only that first number changes; the rest stays as written. Scientific notation is left
/// alone, since rounding its mantissa would change the value's meaning.
nonisolated enum NumberRounding {
    /// `text` with its leading number rounded half away from zero to at most `places` decimal
    /// places, trailing zeros removed. Text that does not start with such a number comes back as is.
    static func round(
        _ text: String, places: Int, decimal: Unicode.Scalar, grouping: Unicode.Scalar?
    ) -> String {
        guard places >= 0, !text.contains("×") else { return text }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var negative = false
        if index < scalars.count, scalars[index] == "-" || scalars[index] == "\u{2212}" {
            negative = true
            index += 1
        }
        var integer: [UInt8] = []
        var sawGrouping = false
        while index < scalars.count {
            let scalar = scalars[index]
            if let digit = digitValue(scalar) {
                integer.append(digit)
            } else if let grouping, scalar == grouping, !integer.isEmpty, index + 1 < scalars.count,
                digitValue(scalars[index + 1]) != nil
            {
                sawGrouping = true
            } else {
                break
            }
            index += 1
        }
        guard !integer.isEmpty, index < scalars.count, scalars[index] == decimal else { return text }
        var fraction: [UInt8] = []
        var end = index + 1
        while end < scalars.count, let digit = digitValue(scalars[end]) {
            fraction.append(digit)
            end += 1
        }
        guard fraction.count > places else { return text }
        // "1.5e30": an exponent follows, so the digits are a mantissa.
        if end < scalars.count, scalars[end] == "e" || scalars[end] == "E" { return text }

        // Round half away from zero on the digits.
        var digits = integer + fraction.prefix(places)
        if fraction[places] >= 5 {
            var position = digits.count - 1
            while position >= 0 {
                if digits[position] == 9 {
                    digits[position] = 0
                    position -= 1
                } else {
                    digits[position] += 1
                    break
                }
            }
            if position < 0 { digits.insert(1, at: 0) }
        }
        let integerCount = digits.count - places
        var integerDigits = Array(digits.prefix(integerCount))
        var fractionDigits = Array(digits.suffix(places))
        while let last = fractionDigits.last, last == 0 { fractionDigits.removeLast() }
        while integerDigits.count > 1, integerDigits.first == 0 { integerDigits.removeFirst() }

        var result = String.UnicodeScalarView()
        let isZero = integerDigits.allSatisfy { $0 == 0 } && fractionDigits.isEmpty
        if negative && !isZero { result.append("-") }
        // Group the way the engine does: by threes, from four digits up, when it grouped at all or
        // grouping is on and the number grew past three digits.
        let groups = grouping != nil && (sawGrouping || integerDigits.count >= 4)
        for (offset, digit) in integerDigits.enumerated() {
            if groups, let grouping, offset > 0, (integerDigits.count - offset) % 3 == 0 { result.append(grouping) }
            result.append(Unicode.Scalar(UInt8(ascii: "0") + digit))
        }
        if !fractionDigits.isEmpty {
            result.append(decimal)
            for digit in fractionDigits { result.append(Unicode.Scalar(UInt8(ascii: "0") + digit)) }
        }
        result.append(contentsOf: scalars[end...])
        return String(result)
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> UInt8? {
        guard ("0"..."9").contains(scalar) else { return nil }
        return UInt8(scalar.value - 48)
    }
}
