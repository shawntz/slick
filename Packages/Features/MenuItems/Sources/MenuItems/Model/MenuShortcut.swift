import Kit

/// The four Accessibility attributes that describe a menu item's keyboard shortcut, as an app
/// reports them. Any of them may be missing.
nonisolated struct ShortcutAttributes: Hashable, Sendable {
    /// `AXMenuItemCmdChar`: the character on the key, such as "S", ",", "?" or "\r".
    var character: String?
    /// `AXMenuItemCmdVirtualKey`: the virtual key code, which few apps report.
    var virtualKey: Int?
    /// `AXMenuItemCmdGlyph`: a glyph code for a key with no character, such as an arrow or F5.
    var glyph: Int?
    /// `AXMenuItemCmdModifiers`: a mask where Command is on unless the no-Command bit is set.
    var modifiers: Int?

    init(character: String? = nil, virtualKey: Int? = nil, glyph: Int? = nil, modifiers: Int? = nil) {
        self.character = character
        self.virtualKey = virtualKey
        self.glyph = glyph
        self.modifiers = modifiers
    }
}

/// Turns a menu item's shortcut attributes into a Kit key combination. Pure, so it is tested
/// without another app.
///
/// The key comes from the first of these that names one:
///
/// 1. The glyph, for keys with no character: arrows, Return, Delete, Escape and the F keys.
/// 2. The character, read on the US layout. A shifted symbol such as "?" or "+" becomes its key
///    with Shift, as in Shift-Command-/. A letter's case means nothing: the mask says whether Shift
///    is held.
/// 3. The virtual key code. An item with no character and no glyph has no shortcut, so a code of 0
///    is read as a key only when a character was given that the US layout cannot place.
///
/// The modifier mask follows the Accessibility header: bit 0 Shift, bit 1 Option, bit 2 Control,
/// bit 3 no Command. Bit 4 is the Function key. It is not in the public header; AppKit sets it for
/// items whose shortcut uses the Function or Globe key, such as Enter Full Screen.
nonisolated enum MenuShortcut {
    static let shiftBit = 1 << 0
    static let optionBit = 1 << 1
    static let controlBit = 1 << 2
    static let noCommandBit = 1 << 3
    static let functionBit = 1 << 4

    /// The key combination, or nil when the item has no shortcut or names a key Kit cannot draw.
    static func combo(_ attributes: ShortcutAttributes) -> KeyCombo? {
        var modifiers = self.modifiers(attributes.modifiers ?? 0)
        let character = attributes.character.flatMap { $0.isEmpty ? nil : $0 }
        if let glyph = attributes.glyph, glyph != 0, let key = key(glyph: glyph) {
            return KeyCombo(key, modifiers)
        }
        if let character {
            if let (key, impliesShift) = key(character: character) {
                if impliesShift { modifiers.insert(.shift) }
                return KeyCombo(key, modifiers)
            }
            // A character the US layout cannot place, such as "ß": the code says where it is.
            if let code = attributes.virtualKey, let key = knownKey(code: code) {
                return KeyCombo(key, modifiers)
            }
            return nil
        }
        if let code = attributes.virtualKey, code != 0, let key = knownKey(code: code) {
            return KeyCombo(key, modifiers)
        }
        return nil
    }

    /// The modifiers a mask names. Command is held unless the no-Command bit is set.
    static func modifiers(_ mask: Int) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if mask & shiftBit != 0 { modifiers.insert(.shift) }
        if mask & optionBit != 0 { modifiers.insert(.option) }
        if mask & controlBit != 0 { modifiers.insert(.control) }
        if mask & noCommandBit == 0 { modifiers.insert(.command) }
        if mask & functionBit != 0 { modifiers.insert(.function) }
        return modifiers
    }

    /// The key a menu glyph code stands for. Codes from the Carbon menu glyph table.
    static func key(glyph: Int) -> Key? {
        if let code = glyphKeys[glyph] { return Key(code: code) }
        return nil
    }

    /// The key a character sits on in the US layout, and whether typing it needs Shift.
    static func key(character: String) -> (key: Key, impliesShift: Bool)? {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            if let code = controlKeys[scalar.value] { return (Key(code: code), false) }
            if let base = shiftedSymbols[Character(scalar)], let key = Key(name: String(base)) { return (key, true) }
            if scalar.isASCII,
                scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                    || unshiftedSymbols.contains(Character(scalar)),
                let key = Key(name: String(Character(scalar)).lowercased())
            {
                return (key, false)
            }
        }
        // Names and keycap symbols some apps report instead of a character, such as "↩" or "F5".
        if character.count <= 6, let key = Key(name: character) { return (key, false) }
        return nil
    }

    /// The key for a virtual key code, when Kit knows its name.
    static func knownKey(code: Int) -> Key? {
        guard (0...0x7F).contains(code) else { return nil }
        let key = Key(code: UInt16(code))
        return key.name.hasPrefix("key") ? nil : key
    }

    // MARK: - Tables

    /// Menu glyph codes for keys, to virtual key codes.
    private static let glyphKeys: [Int: UInt16] = [
        0x02: 0x30,  // tab right
        0x03: 0x30,  // tab left
        0x04: 0x4C,  // enter
        0x09: 0x31,  // space
        0x0A: 0x75,  // delete right, forward delete
        0x0B: 0x24,  // return
        0x0C: 0x24,  // return, right to left
        0x0D: 0x24,  // nonmarking return
        0x17: 0x33,  // delete left
        0x1B: 0x35,  // escape
        0x62: 0x74,  // page up
        0x64: 0x7B,  // left arrow
        0x65: 0x7C,  // right arrow
        0x66: 0x73,  // northwest arrow, home
        0x68: 0x7E,  // up arrow
        0x69: 0x77,  // southeast arrow, end
        0x6A: 0x7D,  // down arrow
        0x6B: 0x79,  // page down
        0x6F: 0x7A, 0x70: 0x78, 0x71: 0x63, 0x72: 0x76, 0x73: 0x60, 0x74: 0x61,  // F1 to F6
        0x75: 0x62, 0x76: 0x64, 0x77: 0x65, 0x78: 0x6D, 0x79: 0x67, 0x7A: 0x6F,  // F7 to F12
        0x87: 0x69, 0x88: 0x6B, 0x89: 0x71,  // F13 to F15
        0x8F: 0x6A, 0x90: 0x40, 0x91: 0x4F, 0x92: 0x50,  // F16 to F19
    ]

    /// Control characters and AppKit's private-use function key characters, to virtual key codes.
    private static let controlKeys: [UInt32: UInt16] = [
        0x03: 0x4C,  // enter
        0x08: 0x33,  // backspace
        0x09: 0x30,  // tab
        0x0D: 0x24,  // return
        0x1B: 0x35,  // escape
        0x20: 0x31,  // space
        0x7F: 0x33,  // delete
        0xF700: 0x7E, 0xF701: 0x7D, 0xF702: 0x7B, 0xF703: 0x7C,  // arrows
        0xF704: 0x7A, 0xF705: 0x78, 0xF706: 0x63, 0xF707: 0x76, 0xF708: 0x60, 0xF709: 0x61,  // F1 to F6
        0xF70A: 0x62, 0xF70B: 0x64, 0xF70C: 0x65, 0xF70D: 0x6D, 0xF70E: 0x67, 0xF70F: 0x6F,  // F7 to F12
        0xF710: 0x69, 0xF711: 0x6B, 0xF712: 0x71, 0xF713: 0x6A, 0xF714: 0x40, 0xF715: 0x4F,  // F13 to F18
        0xF716: 0x50, 0xF717: 0x5A,  // F19, F20
        0xF728: 0x75,  // forward delete
        0xF729: 0x73, 0xF72B: 0x77, 0xF72C: 0x74, 0xF72D: 0x79,  // home, end, page up, page down
    ]

    /// Symbols typed with Shift on the US layout, to the key they sit on.
    private static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]

    /// Symbols typed without Shift on the US layout.
    private static let unshiftedSymbols: Set<Character> = ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
}
