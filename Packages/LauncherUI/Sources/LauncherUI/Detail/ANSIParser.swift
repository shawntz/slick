/// A colour a terminal asked for with an SGR code.
nonisolated public enum ANSIColor: Sendable, Equatable {
    /// One of the 256 palette entries: 0 to 7 normal, 8 to 15 bright, 16 to 231 a 6 by 6 by 6
    /// cube, 232 to 255 a grey ramp.
    case palette(Int)
    /// An exact colour from a 24-bit code.
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

/// The text style that SGR codes set, such as `ESC[1;31m` for bold red.
nonisolated public struct ANSIStyle: Sendable, Equatable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var isBold = false
    public var isDim = false
    public var isItalic = false
    public var isUnderlined = false
    public var isInverse = false
    public var isStruckThrough = false

    public init() {}

    public var isPlain: Bool { self == ANSIStyle() }
}

/// Splits terminal output into runs of text and the style SGR codes give them. Every other escape
/// sequence, such as cursor moves, titles and hyperlinks, is dropped.
///
/// It keeps its state between chunks: a style set in one chunk applies to the next, and a
/// sequence cut in two by a chunk boundary is completed by the next chunk. Feed it the chunks of
/// a stream in order.
nonisolated public struct ANSIParser: Sendable, Equatable {
    /// The style the next text gets.
    public private(set) var style = ANSIStyle()
    /// The start of an escape sequence that the last chunk ended inside.
    private var pending: [Unicode.Scalar] = []

    /// A sequence longer than this is not one; its bytes are dropped.
    private static let longestSequence = 256

    public init() {}

    /// Whether a chunk can be shown as is: no escape inside, nothing pending and no style set.
    public func passesThrough(_ chunk: String) -> Bool {
        pending.isEmpty && style.isPlain && !chunk.unicodeScalars.contains("\u{1B}")
    }

    /// The runs of `chunk`, in order, with their styles. Runs with no text are left out.
    public mutating func parse(_ chunk: String) -> [(text: String, style: ANSIStyle)] {
        var runs: [(text: String, style: ANSIStyle)] = []
        var text = String.UnicodeScalarView()
        func flush() {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += String(text)
            } else {
                runs.append((String(text), style))
            }
            text = String.UnicodeScalarView()
        }
        var scalars = pending
        pending = []
        scalars.append(contentsOf: chunk.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                text.append(scalar)
                index += 1
                continue
            }
            guard let end = Self.sequenceEnd(scalars, from: index) else {
                // Cut by the chunk boundary: keep it for the next chunk, unless it is too long to
                // be a sequence at all.
                if scalars.count - index <= Self.longestSequence { pending = Array(scalars[index...]) }
                break
            }
            flush()
            if scalars[index + 1] == "[", scalars[end - 1] == "m" {
                applySGR(String(String.UnicodeScalarView(scalars[(index + 2)..<(end - 1)])))
            }
            index = end
        }
        flush()
        return runs
    }

    /// The index just past the escape sequence at `start`, or nil when the scalars end first.
    private static func sequenceEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + 1 < scalars.count else { return nil }
        switch scalars[start + 1] {
        case "[":
            // CSI: parameter and intermediate bytes, then one final byte from @ to ~.
            var index = start + 2
            while index < scalars.count {
                if (0x40...0x7E).contains(scalars[index].value) { return index + 1 }
                index += 1
            }
            return nil
        case "]", "P", "_", "^":
            // OSC and other strings: up to BEL or ESC backslash.
            var index = start + 2
            while index < scalars.count {
                if scalars[index] == "\u{07}" { return index + 1 }
                if scalars[index] == "\u{1B}" {
                    guard index + 1 < scalars.count else { return nil }
                    if scalars[index + 1] == "\\" { return index + 2 }
                }
                index += 1
            }
            return nil
        default:
            // A two-character escape such as ESC 7.
            return start + 2
        }
    }

    private mutating func applySGR(_ parameters: String) {
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < max(codes.count, 1) {
            let code = codes.isEmpty ? 0 : codes[index]
            switch code {
            case 0: style = ANSIStyle()
            case 1: style.isBold = true
            case 2: style.isDim = true
            case 3: style.isItalic = true
            case 4: style.isUnderlined = true
            case 7: style.isInverse = true
            case 9: style.isStruckThrough = true
            case 22:
                style.isBold = false
                style.isDim = false
            case 23: style.isItalic = false
            case 24: style.isUnderlined = false
            case 27: style.isInverse = false
            case 29: style.isStruckThrough = false
            case 30...37: style.foreground = .palette(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = .palette(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = .palette(code - 90 + 8)
            case 100...107: style.background = .palette(code - 100 + 8)
            case 38, 48:
                let (color, used) = Self.extendedColor(codes, after: index)
                if code == 38 { style.foreground = color } else { style.background = color }
                index += used
            default: break
            }
            index += 1
        }
    }

    /// A 256-colour or 24-bit colour after a 38 or 48 code, and how many codes it used.
    private static func extendedColor(_ codes: [Int], after index: Int) -> (ANSIColor?, Int) {
        guard index + 1 < codes.count else { return (nil, 0) }
        switch codes[index + 1] {
        case 5:
            guard index + 2 < codes.count else { return (nil, 1) }
            return (.palette(min(255, max(0, codes[index + 2]))), 2)
        case 2:
            guard index + 4 < codes.count else { return (nil, codes.count - index - 1) }
            func byte(_ value: Int) -> UInt8 { UInt8(min(255, max(0, value))) }
            return (.rgb(red: byte(codes[index + 2]), green: byte(codes[index + 3]), blue: byte(codes[index + 4])), 4)
        default:
            return (nil, 1)
        }
    }
}

extension ANSIColor {
    /// The colour as sRGB components from 0 to 1. Palette entries 0 to 15 are nil: the theme
    /// draws them with its own system colours.
    nonisolated var srgb: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .rgb(let red, let green, let blue): return (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        case .palette(let index) where index >= 232:
            let level = Double(8 + (index - 232) * 10) / 255
            return (level, level, level)
        case .palette(let index) where index >= 16:
            let cube = index - 16
            func level(_ step: Int) -> Double { step == 0 ? 0 : Double(55 + step * 40) / 255 }
            return (level(cube / 36), level((cube / 6) % 6), level(cube % 6))
        case .palette: return nil
        }
    }

    /// The theme colour for palette entries 0 to 15, by hue. Bright entries take the same hue.
    nonisolated var system: ThemeColor.System? {
        guard case .palette(let index) = self, index < 16 else { return nil }
        let hues: [ThemeColor.System] = [.gray, .red, .green, .yellow, .blue, .purple, .cyan, .label]
        return hues[index % 8]
    }
}
