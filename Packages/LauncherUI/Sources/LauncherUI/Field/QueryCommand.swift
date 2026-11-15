import AppKit

/// A key press with modifiers, as the host's keyboard model sees it.
nonisolated public struct KeyChord: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The modifiers a chord can carry.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The key without modifiers, lowercased: `"k"`, `"1"`, `","`. Special keys use the names in
    /// `KeyChord.Key`.
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Names for keys that have no printable character.
    public enum Key {
        public static let returnKey = "return"
        public static let escape = "escape"
        public static let tab = "tab"
        public static let delete = "delete"
        public static let up = "up"
        public static let down = "down"
        public static let left = "left"
        public static let right = "right"
        public static let space = "space"
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

extension KeyChord {
    /// The chord for a key event, or nil for any other event or for a key with no name here (a
    /// function key, say). Reading key properties of a non-key event raises an exception, so this
    /// checks the type first.
    @MainActor public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let key: String
        switch event.keyCode {
        case 36, 76: key = Key.returnKey
        case 53: key = Key.escape
        case 48: key = Key.tab
        case 51: key = Key.delete
        case 126: key = Key.up
        case 125: key = Key.down
        case 123: key = Key.left
        case 124: key = Key.right
        case 49: key = Key.space
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            key = characters
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers)
    }
}

/// What the query field asks its host to do for a key it does not handle itself.
nonisolated public enum QueryCommand: Sendable, Equatable {
    /// Up arrow or Control-P.
    case moveUp
    /// Down arrow or Control-N.
    case moveDown
    /// Left arrow. Unclaimed, the caret moves; a grid claims it to move its selection.
    case moveLeft
    /// Right arrow. Unclaimed, the caret moves.
    case moveRight
    /// Command-Up.
    case moveToPreviousSection
    /// Command-Down.
    case moveToNextSection
    /// Return, with the modifiers held (Command-Return runs the secondary action).
    case submit(KeyChord.Modifiers)
    /// Escape, with the modifiers held (Command-Escape goes back to root).
    case cancel(KeyChord.Modifiers)
    /// Tab: accept the completion or move to the next argument.
    case complete
    /// Shift-Tab.
    case completeBackward
    /// Delete while the query is empty: go back.
    case deleteOnEmpty
    /// The back chevron or the breadcrumb was clicked.
    case back
    /// Any other Command chord, such as Command-K or Command-1.
    case chord(KeyChord)
}
