/// What a query typed in root search asks the feature for.
nonisolated enum ColorQuery: Hashable, Sendable {
    /// One color to convert.
    case color(ColorValue)
    /// Text in one color over another.
    case contrast(foreground: ColorValue, background: ColorValue)

    /// What the first bytes of a query promise, before anything is parsed.
    enum Kind: Hashable, Sendable {
        /// `#` and hex digits.
        case hex
        /// A CSS function such as `rgb(`.
        case function
        /// The keyword `color` and one color, which may be a CSS name.
        case keyword
        /// The keyword `contrast` and two colors.
        case contrast
    }

    /// The longest query the feature reads, in bytes. Longer text is pasted, not typed.
    static let maximumBytes = 200

    /// The words that can start a query the feature answers, in lowercase, after the first byte.
    /// A query must start with one of them exactly, in any case.
    private static let openings: [(word: String, kind: Kind)] = [
        ("rgb(", .function), ("rgba(", .function), ("hsl(", .function), ("hsla(", .function),
        ("hwb(", .function), ("oklch(", .function), ("color ", .keyword), ("contrast ", .contrast),
    ]

    /// The longest opening, so a test can check that nothing past it is read.
    static let longestOpening = 9

    /// What the query may be, from its first bytes alone: at most ``longestOpening`` of them, and
    /// for most text only the first. Nil for a query the feature never answers. This is the
    /// keystroke path's gate, so it allocates nothing and parses nothing.
    static func kind<Bytes: Collection<UInt8>>(of bytes: Bytes) -> Kind? {
        guard let first = bytes.first else { return nil }
        if first == UInt8(ascii: "#") { return .hex }
        switch first | 0x20 {
        case UInt8(ascii: "r"), UInt8(ascii: "h"), UInt8(ascii: "o"), UInt8(ascii: "c"): break
        default: return nil
        }
        for opening in openings where startsWith(bytes, opening.word) {
            return opening.kind
        }
        return nil
    }

    /// The query parsed in full, or nil. Call it only after ``kind(of:)`` said yes.
    static func parse(_ query: String, kind: Kind) -> ColorQuery? {
        let utf8 = query.utf8
        guard utf8.count <= maximumBytes else { return nil }
        let bytes = Array(utf8)[...]
        switch kind {
        case .hex, .function:
            return ColorParser.parse(bytes: bytes, allowsNames: false).map(ColorQuery.color)
        case .keyword:
            let rest = bytes.dropFirst("color ".utf8.count)
            return ColorParser.parse(bytes: rest, allowsNames: true).map(ColorQuery.color)
        case .contrast:
            let rest = bytes.dropFirst("contrast ".utf8.count)
            guard let tokens = tokens(rest), tokens.count == 2,
                let foreground = ColorParser.parse(bytes: tokens[0], allowsNames: true),
                let background = ColorParser.parse(bytes: tokens[1], allowsNames: true)
            else { return nil }
            return .contrast(foreground: foreground, background: background)
        }
    }

    /// Words between two colors that read naturally and mean nothing, as in "contrast black on
    /// white".
    private static let connectors = ["on", "vs", "vs.", "and", "against", "over"]

    /// The colors of a contrast query: the text split on spaces, tabs and commas outside
    /// parentheses, without connecting words. Nil when the parentheses do not balance.
    static func tokens(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>]? {
        var tokens: [ArraySlice<UInt8>] = []
        var depth = 0
        var start: Int?
        func close(at end: Int) {
            guard let begin = start else { return }
            let token = bytes[begin..<end]
            if !connectors.contains(where: { ColorParser.equalsIgnoringCase(token, $0) }) { tokens.append(token) }
            start = nil
        }
        for index in bytes.indices {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                guard depth >= 0 else { return nil }
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: ","):
                if depth == 0 {
                    close(at: index)
                    continue
                }
            default:
                break
            }
            if start == nil { start = index }
        }
        guard depth == 0 else { return nil }
        close(at: bytes.endIndex)
        return tokens
    }

    /// True when the bytes start with `word`, a lowercase ASCII word, in any case. Reads at most as
    /// many bytes as the word has, and stops at the first that differs.
    private static func startsWith<Bytes: Collection<UInt8>>(_ bytes: Bytes, _ word: String) -> Bool {
        var iterator = bytes.makeIterator()
        for letter in word.utf8 {
            guard let byte = iterator.next() else { return false }
            let folded = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
            guard folded == letter else { return false }
        }
        return true
    }
}
