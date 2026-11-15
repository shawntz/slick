/// A physical key, by macOS virtual key code (the `kVK_` constants in Carbon's `Events.h`).
///
/// Names and symbols follow the US ANSI layout. A hotkey is stored by key code, so it stays on the
/// same physical key when the user switches layouts; the host may show the label of the current
/// layout instead of ``symbol``.
public struct Key: Hashable, Sendable, CustomStringConvertible {
    /// The virtual key code.
    public let code: UInt16

    public init(code: UInt16) {
        self.code = code
    }

    /// Looks a key up by name or symbol: "k", "return", "↩", "esc", "f5", "left", "space", "-".
    /// Case does not matter.
    public init?(name: some StringProtocol) {
        let lowered = name.lowercased()
        guard let code = Self.codesByName[lowered] ?? Self.aliases[lowered] else { return nil }
        self.code = code
    }

    /// The canonical lowercase name, such as "k", "return" or "f5". Unknown codes read "key<code>".
    public var name: String {
        Self.table[code]?.name ?? "key\(code)"
    }

    /// What the key looks like on a keycap: "K", "↩", "⎋", "F5", "Space".
    public var symbol: String {
        Self.table[code]?.symbol ?? "key\(code)"
    }

    public var description: String { name }

    private static let entries: [(code: UInt16, name: String, symbol: String)] = [
        (0x00, "a", "A"), (0x0B, "b", "B"), (0x08, "c", "C"), (0x02, "d", "D"), (0x0E, "e", "E"),
        (0x03, "f", "F"), (0x05, "g", "G"), (0x04, "h", "H"), (0x22, "i", "I"), (0x26, "j", "J"),
        (0x28, "k", "K"), (0x25, "l", "L"), (0x2E, "m", "M"), (0x2D, "n", "N"), (0x1F, "o", "O"),
        (0x23, "p", "P"), (0x0C, "q", "Q"), (0x0F, "r", "R"), (0x01, "s", "S"), (0x11, "t", "T"),
        (0x20, "u", "U"), (0x09, "v", "V"), (0x0D, "w", "W"), (0x07, "x", "X"), (0x10, "y", "Y"),
        (0x06, "z", "Z"),
        (0x1D, "0", "0"), (0x12, "1", "1"), (0x13, "2", "2"), (0x14, "3", "3"), (0x15, "4", "4"),
        (0x17, "5", "5"), (0x16, "6", "6"), (0x1A, "7", "7"), (0x1C, "8", "8"), (0x19, "9", "9"),
        (0x24, "return", "↩"), (0x4C, "enter", "⌤"), (0x30, "tab", "⇥"), (0x31, "space", "Space"),
        (0x33, "delete", "⌫"), (0x75, "forwarddelete", "⌦"), (0x35, "escape", "⎋"),
        (0x73, "home", "↖"), (0x77, "end", "↘"), (0x74, "pageup", "⇞"), (0x79, "pagedown", "⇟"),
        (0x7B, "left", "←"), (0x7C, "right", "→"), (0x7D, "down", "↓"), (0x7E, "up", "↑"),
        (0x1B, "-", "-"), (0x18, "=", "="), (0x21, "[", "["), (0x1E, "]", "]"), (0x2A, "\\", "\\"),
        (0x29, ";", ";"), (0x27, "'", "'"), (0x2B, ",", ","), (0x2F, ".", "."), (0x2C, "/", "/"),
        (0x32, "`", "`"),
        (0x7A, "f1", "F1"), (0x78, "f2", "F2"), (0x63, "f3", "F3"), (0x76, "f4", "F4"), (0x60, "f5", "F5"),
        (0x61, "f6", "F6"), (0x62, "f7", "F7"), (0x64, "f8", "F8"), (0x65, "f9", "F9"), (0x6D, "f10", "F10"),
        (0x67, "f11", "F11"), (0x6F, "f12", "F12"), (0x69, "f13", "F13"), (0x6B, "f14", "F14"),
        (0x71, "f15", "F15"), (0x6A, "f16", "F16"), (0x40, "f17", "F17"), (0x4F, "f18", "F18"),
        (0x50, "f19", "F19"), (0x5A, "f20", "F20"),
    ]

    private static let table: [UInt16: (name: String, symbol: String)] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.code, ($0.name, $0.symbol)) })

    private static let codesByName: [String: UInt16] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.name, $0.code) })

    private static let aliases: [String: UInt16] = [
        "↩": 0x24, "ret": 0x24, "⌤": 0x4C, "⇥": 0x30, "␣": 0x31, "spacebar": 0x31,
        "⌫": 0x33, "backspace": 0x33, "⌦": 0x75, "del": 0x75, "fwddelete": 0x75,
        "⎋": 0x35, "esc": 0x35, "↖": 0x73, "↘": 0x77, "⇞": 0x74, "pgup": 0x74, "⇟": 0x79, "pgdown": 0x79,
        "←": 0x7B, "→": 0x7C, "↓": 0x7D, "↑": 0x7E, "leftarrow": 0x7B, "rightarrow": 0x7C,
        "downarrow": 0x7D, "uparrow": 0x7E, "minus": 0x1B, "equal": 0x18, "comma": 0x2B,
        "period": 0x2F, "slash": 0x2C, "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27, "grave": 0x32,
    ]
}

extension Key {
    public static let a = Key(code: 0x00)
    public static let b = Key(code: 0x0B)
    public static let c = Key(code: 0x08)
    public static let d = Key(code: 0x02)
    public static let e = Key(code: 0x0E)
    public static let f = Key(code: 0x03)
    public static let g = Key(code: 0x05)
    public static let h = Key(code: 0x04)
    public static let i = Key(code: 0x22)
    public static let j = Key(code: 0x26)
    public static let k = Key(code: 0x28)
    public static let l = Key(code: 0x25)
    public static let m = Key(code: 0x2E)
    public static let n = Key(code: 0x2D)
    public static let o = Key(code: 0x1F)
    public static let p = Key(code: 0x23)
    public static let q = Key(code: 0x0C)
    public static let r = Key(code: 0x0F)
    public static let s = Key(code: 0x01)
    public static let t = Key(code: 0x11)
    public static let u = Key(code: 0x20)
    public static let v = Key(code: 0x09)
    public static let w = Key(code: 0x0D)
    public static let x = Key(code: 0x07)
    public static let y = Key(code: 0x10)
    public static let z = Key(code: 0x06)
    public static let `return` = Key(code: 0x24)
    public static let tab = Key(code: 0x30)
    public static let space = Key(code: 0x31)
    public static let delete = Key(code: 0x33)
    public static let forwardDelete = Key(code: 0x75)
    public static let escape = Key(code: 0x35)
    public static let leftArrow = Key(code: 0x7B)
    public static let rightArrow = Key(code: 0x7C)
    public static let downArrow = Key(code: 0x7D)
    public static let upArrow = Key(code: 0x7E)
    public static let period = Key(code: 0x2F)
    public static let comma = Key(code: 0x2B)
}

/// The digit row and the two keys beside it, on a US ANSI layout. Their codes are the
/// `kVK_ANSI_` constants, so a combination stays on the same physical key in every layout.
extension Key {
    public static let zero = Key(code: 0x1D)
    public static let one = Key(code: 0x12)
    public static let two = Key(code: 0x13)
    public static let three = Key(code: 0x14)
    public static let four = Key(code: 0x15)
    public static let five = Key(code: 0x17)
    public static let six = Key(code: 0x16)
    public static let seven = Key(code: 0x1A)
    public static let eight = Key(code: 0x1C)
    public static let nine = Key(code: 0x19)
    /// The "-" key.
    public static let minus = Key(code: 0x1B)
    /// The "=" key.
    public static let equal = Key(code: 0x18)
}
