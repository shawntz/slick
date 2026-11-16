/// Reads one color as CSS writes it: hex behind a number sign, the functions rgb, rgba, hsl, hsla,
/// hwb and oklch in the comma and the space forms, and, where the caller allows it, a CSS name.
///
/// It follows CSS Color 4 and is lenient where that costs nothing: function names and hex digits
/// in any case, spaces around commas and parentheses, numbers or percentages wherever either makes
/// sense, and `none` for a missing component. Values out of range are clamped as CSS clamps them.
/// The whole text must be one color; anything else gives nil.
nonisolated enum ColorParser {
    /// The longest text the parser reads, in bytes. A longer text is pasted, not typed.
    static let maximumBytes = 160

    /// The color the text names, or nil.
    static func parse(_ text: some StringProtocol, allowsNames: Bool) -> ColorValue? {
        let utf8 = text.utf8
        guard utf8.count <= maximumBytes else { return nil }
        return parse(bytes: Array(utf8)[...], allowsNames: allowsNames)
    }

    static func parse(bytes: ArraySlice<UInt8>, allowsNames: Bool) -> ColorValue? {
        let text = trimmed(bytes)
        guard let first = text.first, text.count <= maximumBytes else { return nil }
        if first == UInt8(ascii: "#") { return hex(text.dropFirst()) }
        if let open = text.firstIndex(of: UInt8(ascii: "(")) {
            guard text.last == UInt8(ascii: ")") else { return nil }
            return function(name: text[..<open], body: text[(open + 1)..<(text.endIndex - 1)])
        }
        return allowsNames ? CSSNames.color(named: text) : nil
    }

    // MARK: Hex

    /// Three, four, six or eight hex digits, the last of four or eight being alpha.
    static func hex(_ digits: ArraySlice<UInt8>) -> ColorValue? {
        guard [3, 4, 6, 8].contains(digits.count) else { return nil }
        var values: [Int] = []
        values.reserveCapacity(8)
        for byte in digits {
            guard let value = hexValue(byte) else { return nil }
            values.append(value)
        }
        let components: [Int]
        if digits.count <= 4 {
            components = values.map { $0 * 17 }
        } else {
            components = stride(from: 0, to: values.count, by: 2).map { values[$0] * 16 + values[$0 + 1] }
        }
        let alpha = components.count == 4 ? Double(components[3]) / 255 : 1
        return ColorValue(bytes: components[0], components[1], components[2], alpha: alpha)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }

    // MARK: Functions

    /// The CSS functions the parser reads.
    enum Function: String, CaseIterable, Sendable {
        case rgb, rgba, hsl, hsla, hwb, oklch
    }

    static func function(name: ArraySlice<UInt8>, body: ArraySlice<UInt8>) -> ColorValue? {
        guard let function = Function.allCases.first(where: { equalsIgnoringCase(name, $0.rawValue) }),
            let arguments = Arguments(body)
        else { return nil }
        let values = arguments.values
        var alpha = 1.0
        if let component = arguments.alpha {
            guard let value = alphaValue(component) else { return nil }
            alpha = value
        }
        let color: ColorValue?
        switch function {
        case .rgb, .rgba:
            guard let red = channel(values[0]), let green = channel(values[1]), let blue = channel(values[2]) else {
                return nil
            }
            color = ColorValue(red: red, green: green, blue: blue, alpha: alpha)
        case .hsl, .hsla:
            guard let hue = hue(values[0]), let saturation = fraction(values[1]), let lightness = fraction(values[2])
            else { return nil }
            color = ColorSpaces.color(HSL(hue: hue, saturation: saturation, lightness: lightness), alpha: alpha)
        case .hwb:
            guard let hue = hue(values[0]), let white = fraction(values[1]), let black = fraction(values[2]) else {
                return nil
            }
            color = ColorSpaces.color(HWB(hue: hue, whiteness: white, blackness: black), alpha: alpha)
        case .oklch:
            guard let lightness = oklchLightness(values[0]), let chroma = oklchChroma(values[1]),
                let hue = hue(values[2])
            else { return nil }
            color = ColorSpaces.color(OKLCH(lightness: lightness, chroma: chroma, hue: hue), alpha: alpha)
        }
        return color?.sanitized
    }

    /// An rgb component: 0 to 255, or a percentage.
    private static func channel(_ value: Component) -> Double? {
        switch value {
        case .missing: 0
        case .number(let number, .plain): ColorValue.unit(number / 255)
        case .number(let number, .percent): ColorValue.unit(number / 100)
        default: nil
        }
    }

    /// A saturation, lightness, whiteness or blackness: a percentage, or a number of percent as CSS
    /// Color 4 allows.
    private static func fraction(_ value: Component) -> Double? {
        switch value {
        case .missing: 0
        case .number(let number, .plain), .number(let number, .percent): ColorValue.unit(number / 100)
        default: nil
        }
    }

    /// A hue: a number of degrees or an angle.
    private static func hue(_ value: Component) -> Double? {
        switch value {
        case .missing: 0
        case .number(let number, let unit):
            switch unit {
            case .plain, .deg: ColorSpaces.normalizedHue(number)
            case .rad: ColorSpaces.normalizedHue(number * 180 / .pi)
            case .grad: ColorSpaces.normalizedHue(number * 0.9)
            case .turn: ColorSpaces.normalizedHue(number * 360)
            case .percent: nil
            }
        }
    }

    /// OKLCH lightness: 0 to 1, or a percentage.
    private static func oklchLightness(_ value: Component) -> Double? {
        switch value {
        case .missing: 0
        case .number(let number, .plain): ColorValue.unit(number)
        case .number(let number, .percent): ColorValue.unit(number / 100)
        default: nil
        }
    }

    /// The most chroma the parser takes. The most vivid colors any screen shows stay under 0.4.
    static let maximumChroma = 0.5

    /// OKLCH chroma: a number, or a percentage of 0.4 as CSS Color 4 says.
    private static func oklchChroma(_ value: Component) -> Double? {
        let chroma: Double
        switch value {
        case .missing: chroma = 0
        case .number(let number, .plain): chroma = number
        case .number(let number, .percent): chroma = number / 100 * 0.4
        default: return nil
        }
        return min(max(chroma, 0), maximumChroma)
    }

    /// Alpha: 0 to 1, or a percentage.
    private static func alphaValue(_ value: Component) -> Double? {
        switch value {
        case .missing: 0
        case .number(let number, .plain): ColorValue.unit(number)
        case .number(let number, .percent): ColorValue.unit(number / 100)
        default: nil
        }
    }

    // MARK: Arguments

    /// A unit after a number.
    enum Unit: Sendable {
        case plain, percent, deg, rad, grad, turn
    }

    /// One value inside a function.
    enum Component: Sendable {
        /// The keyword `none`, which reads as 0.
        case missing
        case number(Double, Unit)
    }

    /// The three values and the optional alpha inside a function's parentheses.
    struct Arguments {
        var values: [Component]
        var alpha: Component?

        /// Reads `a, b, c[, d]` or `a b c[ / d]`. Nil for any other shape.
        init?(_ body: ArraySlice<UInt8>) {
            var scanner = Scanner(bytes: body)
            var components: [Component] = []
            var separators: [UInt8] = []
            while true {
                scanner.skipSpaces()
                guard let component = scanner.component() else { return nil }
                components.append(component)
                guard components.count <= 4 else { return nil }
                let hadSpace = scanner.skipSpaces()
                guard let next = scanner.peek() else { break }
                if next == UInt8(ascii: ",") || next == UInt8(ascii: "/") {
                    separators.append(next)
                    scanner.advance()
                } else if hadSpace {
                    separators.append(UInt8(ascii: " "))
                } else {
                    return nil
                }
            }
            let commas = separators.filter { $0 == UInt8(ascii: ",") }.count
            if commas > 0 {
                // The comma form: every separator a comma, three or four values.
                guard commas == separators.count, components.count == 3 || components.count == 4 else { return nil }
            } else {
                // The space form: three values, then a slash and alpha.
                switch components.count {
                case 3: guard separators == [UInt8(ascii: " "), UInt8(ascii: " ")] else { return nil }
                case 4:
                    guard separators == [UInt8(ascii: " "), UInt8(ascii: " "), UInt8(ascii: "/")] else { return nil }
                default: return nil
                }
            }
            values = Array(components.prefix(3))
            alpha = components.count == 4 ? components[3] : nil
        }
    }

    /// Reads numbers, units and `none` from bytes.
    struct Scanner {
        let bytes: ArraySlice<UInt8>
        var index: Int

        init(bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        func peek() -> UInt8? {
            index < bytes.endIndex ? bytes[index] : nil
        }

        mutating func advance() {
            index += 1
        }

        /// Skips spaces and tabs, and returns true when there were any.
        @discardableResult
        mutating func skipSpaces() -> Bool {
            let start = index
            while let byte = peek(), byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") { advance() }
            return index > start
        }

        /// A number with an optional unit, or `none`.
        mutating func component() -> Component? {
            guard let first = peek() else { return nil }
            if isLetter(first) {
                let word = letters()
                return equalsIgnoringCase(word, "none") ? .missing : nil
            }
            guard let number = number() else { return nil }
            if peek() == UInt8(ascii: "%") {
                advance()
                return .number(number, .percent)
            }
            guard let next = peek(), isLetter(next) else { return .number(number, .plain) }
            let word = letters()
            for (name, unit) in [("deg", Unit.deg), ("rad", .rad), ("grad", .grad), ("turn", .turn)]
            where equalsIgnoringCase(word, name) {
                return .number(number, unit)
            }
            return nil
        }

        private mutating func letters() -> ArraySlice<UInt8> {
            let start = index
            while let byte = peek(), isLetter(byte) { advance() }
            return bytes[start..<index]
        }

        /// A CSS number: an optional sign, digits with an optional fraction, and an optional
        /// exponent. Nil when there is none, or when it is too large to be finite.
        private mutating func number() -> Double? {
            let start = index
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { advance() }
            let wholeDigits = digits()
            var fractionDigits = 0
            if peek() == UInt8(ascii: "."), index + 1 < bytes.endIndex, isDigit(bytes[index + 1]) {
                advance()
                fractionDigits = digits()
            }
            guard wholeDigits + fractionDigits > 0 else {
                index = start
                return nil
            }
            if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                let mark = index
                advance()
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { advance() }
                if digits() == 0 { index = mark }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
                return nil
            }
            return value
        }

        private mutating func digits() -> Int {
            let start = index
            while let byte = peek(), isDigit(byte) { advance() }
            return index - start
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }

        private func isLetter(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }

    // MARK: Helpers

    /// The bytes without spaces and tabs at either end.
    static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var text = bytes
        while let first = text.first, first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
            text = text.dropFirst()
        }
        while let last = text.last, last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") { text = text.dropLast() }
        return text
    }

    /// True when the bytes spell `word`, a lowercase ASCII word, in any case.
    static func equalsIgnoringCase(_ bytes: some Collection<UInt8>, _ word: String) -> Bool {
        guard bytes.count == word.utf8.count else { return false }
        return zip(bytes, word.utf8).allSatisfy { byte, letter in
            byte == letter || ((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) && byte + 32 == letter)
        }
    }
}
