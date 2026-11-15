import Kit

/// ANSI escape sequences in script output.
///
/// Full output keeps them: the host draws them as color. Toasts, HUDs and subtitles hold one plain
/// line, so this strips the sequences there and reads the first foreground color for a subtitle.
nonisolated enum ANSI {
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"

    /// The text without escape sequences: CSI sequences such as colors and cursor moves, OSC
    /// sequences such as window titles, and two-character escapes.
    static func strip(_ text: String) -> String {
        guard text.unicodeScalars.contains(escape) else { return text }
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == escape else {
                result.append(scalar)
                continue
            }
            switch scalars.next() {
            case "[":
                // Parameters and intermediates, then one final byte from "@" to "~".
                while let next = scalars.next(), !("@"..."~").contains(next) {}
            case "]":
                // Ends with BEL or with ESC "\".
                while let next = scalars.next(), next != bell {
                    if next == escape {
                        _ = scalars.next()
                        break
                    }
                }
            default:
                break
            }
        }
        return String(result)
    }

    /// The foreground color set before the first visible character, for an inline subtitle.
    static func leadingColor(_ text: String) -> KitColor? {
        var color: KitColor?
        var rest = Substring(text)
        while rest.unicodeScalars.first == escape {
            rest = rest.dropFirst()
            guard rest.first == "[" else { return color }
            rest = rest.dropFirst()
            let parameters = rest.prefix { $0.isNumber || $0 == ";" }
            rest = rest.dropFirst(parameters.count)
            guard rest.first == "m" else { return color }
            rest = rest.dropFirst()
            color = foreground(in: parameters.split(separator: ";", omittingEmptySubsequences: false)) ?? color
        }
        return color
    }

    /// The last foreground color in one SGR sequence's parameters.
    private static func foreground(in parameters: [Substring]) -> KitColor? {
        let codes = parameters.map { Int($0) ?? 0 }
        var color: KitColor?
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 30...37: color = basic(code - 30)
            case 90...97: color = basic(code - 90)
            case 38 where index + 4 < codes.count && codes[index + 1] == 2:
                let (red, green, blue) = (codes[index + 2], codes[index + 3], codes[index + 4])
                color = .rgba(
                    red: Double(min(red, 255)) / 255, green: Double(min(green, 255)) / 255,
                    blue: Double(min(blue, 255)) / 255, alpha: 1)
                index += 4
            case 38 where index + 2 < codes.count && codes[index + 1] == 5:
                color = codes[index + 2] < 16 ? basic(codes[index + 2] % 8) : nil
                index += 2
            case 0, 39: color = nil
            default: break
            }
            index += 1
        }
        return color
    }

    private static func basic(_ index: Int) -> KitColor? {
        switch index {
        case 0: .gray
        case 1: .red
        case 2: .green
        case 3: .yellow
        case 4: .blue
        case 5: .purple
        case 6: .blue
        default: nil
        }
    }
}
