import AppKit

/// Builds key events for driving a panel without the keyboard. Send them with
/// `window.sendEvent(_:)`: that reaches a panel that is not key, so nothing takes focus. Nothing
/// here posts events to the system. The window parameter is kept for call sites that route by
/// window; the events themselves carry no window.
public enum SyntheticEvents {
    /// US ANSI virtual key codes. Key bindings and input methods look at the code, not only the
    /// characters.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
        "-": 27, ",": 43, ".": 47,
    ]

    /// A key-down event typing `character`.
    public static func key(_ character: Character, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow)
        -> NSEvent?
    {
        let text = String(character)
        return event(
            characters: text, keyCode: keyCodes[Character(text.lowercased())] ?? 0, modifiers: modifiers, in: window)
    }

    /// A key-down event for Delete (backspace).
    public static func delete(in window: NSWindow) -> NSEvent? {
        event(characters: "\u{7F}", keyCode: 51, modifiers: [], in: window)
    }

    /// A key-down event for Return.
    public static func returnKey(modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        event(characters: "\r", keyCode: 36, modifiers: modifiers, in: window)
    }

    /// A key-down event for Escape.
    public static func escape(modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        event(characters: "\u{1B}", keyCode: 53, modifiers: modifiers, in: window)
    }

    /// A key-down event for the down or up arrow.
    public static func arrow(down: Bool, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        let scalar = UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey).map(String.init) ?? ""
        return event(
            characters: scalar, keyCode: down ? 125 : 126, modifiers: modifiers.union([.numericPad, .function]),
            in: window)
    }

    /// Builds the event from a `CGEvent`, as real key presses are. An event made with
    /// `NSEvent.keyEvent` alone has no system event behind it, and the text input system of a
    /// running app fails on it for arrow keys. Creating a `CGEvent` needs no permission; only
    /// posting one does, and these are never posted.
    private static func event(
        characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow
    ) -> NSEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return nil }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        event.flags = flags
        let units = Array(characters.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        return NSEvent(cgEvent: event)
    }
}
