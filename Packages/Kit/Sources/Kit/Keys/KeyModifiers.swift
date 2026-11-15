/// Modifier keys, with the same bit layout as AppKit's `NSEvent.ModifierFlags`, so Platform converts
/// with `NSEvent.ModifierFlags(rawValue: UInt(modifiers.rawValue))` and back with no table.
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 17)
    public static let control = KeyModifiers(rawValue: 1 << 18)
    public static let option = KeyModifiers(rawValue: 1 << 19)
    public static let command = KeyModifiers(rawValue: 1 << 20)
    public static let function = KeyModifiers(rawValue: 1 << 23)

    /// The modifiers in the order macOS draws them, with their symbol and canonical name.
    static let ordered: [(modifier: KeyModifiers, symbol: String, name: String)] = [
        (.function, "fn", "fn"),
        (.control, "⌃", "ctrl"),
        (.option, "⌥", "opt"),
        (.shift, "⇧", "shift"),
        (.command, "⌘", "cmd"),
    ]

    /// The symbols as macOS shows them in menus, such as "⌃⌥⌘".
    public var symbols: String {
        Self.ordered.filter { contains($0.modifier) }.map(\.symbol).joined()
    }

    /// Parses one modifier name or symbol: "cmd", "command", "⌘", "opt", "option", "alt", "⌥",
    /// "ctrl", "control", "⌃", "shift", "⇧", "fn" or "function". Case does not matter.
    public init?(name: some StringProtocol) {
        switch name.lowercased() {
        case "cmd", "command", "⌘": self = .command
        case "opt", "option", "alt", "⌥": self = .option
        case "ctrl", "control", "⌃": self = .control
        case "shift", "⇧": self = .shift
        case "fn", "function": self = .function
        default: return nil
        }
    }
}
