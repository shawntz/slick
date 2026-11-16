import Foundation

/// A key plus modifiers: a shortcut inside the panel or a global hotkey.
///
/// It reads and writes a canonical text form, "ctrl+opt+shift+cmd+k", which is also its Codable
/// form, so settings files stay readable. ``displayString`` is what people see: "⌃⌥⇧⌘K".
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public var key: Key
    public var modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The combination as macOS draws it in menus: modifier symbols, then the key, as in "⇧⌘K".
    public var displayString: String {
        modifiers.symbols + key.symbol
    }

    /// The canonical text form: modifier names in macOS order, then the key name, joined by "+".
    public var description: String {
        (KeyModifiers.ordered.filter { modifiers.contains($0.modifier) }.map(\.name) + [key.name])
            .joined(separator: "+")
    }

    /// Parses the forms people write: "cmd+shift+k", "Command-Shift-K", "ctrl opt space", "⌘⇧K",
    /// "⌥↩", "cmd+-". Modifier and key names are those of ``KeyModifiers/init(name:)`` and
    /// ``Key/init(name:)``. Returns nil for anything else.
    public init?(parsing text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers: KeyModifiers = []
        // Leading symbols, as in "⌘⇧K".
        while let first = rest.first, "⌃⌥⇧⌘".contains(first), rest.count > 1,
            let modifier = KeyModifiers(name: String(first))
        {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        guard let tokens = Self.tokens(rest), let keyName = tokens.last, let key = Key(name: keyName) else {
            return nil
        }
        for token in tokens.dropLast() {
            guard let modifier = KeyModifiers(name: token) else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key, modifiers)
    }

    /// Splits on "+", "-" and spaces. A trailing "-" or "+" right after a separator is the key itself,
    /// as in "cmd+-" or "cmd--".
    private static func tokens(_ text: Substring) -> [Substring]? {
        guard !text.isEmpty else { return nil }
        if text.count == 1 { return [text] }
        let separators: Set<Character> = ["+", "-", " "]
        var body = text
        var trailingKey: Substring?
        if let last = body.last, last == "-" || last == "+" {
            let beforeLast = body.dropLast().last
            if beforeLast.map(separators.contains) ?? true {
                trailingKey = body.suffix(1)
                body = body.dropLast(2)
            }
        }
        var parts = body.split(whereSeparator: separators.contains)
        if let trailingKey { parts.append(trailingKey) }
        return parts.isEmpty ? nil : parts
    }
}

extension KeyCombo: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let combo = KeyCombo(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a key combination: \(text)")
        }
        self = combo
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The shortcuts people already know from other launchers. Use them for the matching actions so the
/// same key does the same thing in every feature.
extension KeyCombo {
    /// Return: the primary action.
    public static let primaryAction = KeyCombo(.return)
    /// Command-Return: the secondary action.
    public static let secondaryAction = KeyCombo(.return, .command)
    /// Command-O.
    public static let open = KeyCombo(.o, .command)
    /// Option-Command-O.
    public static let openWith = KeyCombo(.o, [.option, .command])
    /// Shift-Command-O.
    public static let reveal = KeyCombo(.o, [.shift, .command])
    /// Command-Y.
    public static let quickLook = KeyCombo(.y, .command)
    /// Shift-Command-C.
    public static let copy = KeyCombo(.c, [.shift, .command])
    /// Control-Command-C.
    public static let copyPath = KeyCombo(.c, [.control, .command])
    /// Control-X.
    public static let remove = KeyCombo(.x, .control)
    /// Control-Shift-X.
    public static let removeAll = KeyCombo(.x, [.control, .shift])
    /// Command-E.
    public static let edit = KeyCombo(.e, .command)
    /// Command-D.
    public static let duplicate = KeyCombo(.d, .command)
    /// Command-N.
    public static let new = KeyCombo(.n, .command)
    /// Command-period.
    public static let pin = KeyCombo(.period, .command)
    /// Command-R.
    public static let refresh = KeyCombo(.r, .command)
    /// Command-L: Show in Large Type.
    public static let largeType = KeyCombo(.l, .command)
}
