/// Global hotkeys. The host already binds the hotkeys users assign to commands; a feature uses this
/// only for a hotkey that is not a command, and unregisters it in ``Feature/deactivate()``.
public protocol HotkeyService: Sendable {
    /// Registers a hotkey under an ID unique to the caller. Registering the same ID again replaces it.
    /// Throws ``HotkeyError`` when the system refuses or another hotkey already uses the combination.
    func register(_ combo: KeyCombo, id: String, handler: @escaping @MainActor @Sendable () -> Void) throws

    /// Removes a hotkey. Unknown IDs are ignored.
    func unregister(id: String)

    /// Hotkeys the system or Slick already binds to this combination. Never registers anything.
    func conflicts(for combo: KeyCombo) -> [HotkeyConflict]

    /// Turns off the macOS shortcut that uses the combination, when its conflict says
    /// ``HotkeyConflict/canTurnOff``, and reads the system's shortcuts again. Only the host calls
    /// it, for the launcher's own hotkey, after the person agreed. Returns the shortcut it turned
    /// off when the combination is free afterwards, and nil when it is not: then nothing else
    /// changed. The default does nothing and returns nil.
    @concurrent func turnOffSystemShortcut(for combo: KeyCombo) async -> SystemShortcut?

    /// Turns a shortcut that ``turnOffSystemShortcut(for:)`` turned off back on, in the same way.
    /// True when the system reads it on again. The default does nothing and returns false.
    @concurrent func turnOnSystemShortcut(_ shortcut: SystemShortcut) async -> Bool
}

extension HotkeyService {
    @concurrent public func turnOffSystemShortcut(for combo: KeyCombo) async -> SystemShortcut? { nil }

    @concurrent public func turnOnSystemShortcut(_ shortcut: SystemShortcut) async -> Bool { false }
}

/// A macOS keyboard shortcut that Slick can turn off when the person asks, such as Spotlight's.
public struct SystemShortcut: Hashable, Sendable {
    /// The system's number for the shortcut, such as 64 for Show Spotlight search.
    public var number: Int
    /// Who owns it, such as "Spotlight".
    public var owner: String

    public init(number: Int, owner: String) {
        self.number = number
        self.owner = owner
    }
}

/// Something else that uses a key combination.
public struct HotkeyConflict: Hashable, Sendable {
    /// Who owns it, such as "Spotlight" or a command's title.
    public var owner: String
    /// True when Slick may take the combination over after asking the user.
    public var canOverride: Bool
    /// True when an enabled macOS keyboard shortcut uses the combination, such as Spotlight's.
    /// Slick never registers over it. The launcher hotkey alone may wait for that shortcut to be
    /// turned off; every other hotkey is refused.
    public var isSystemShortcut: Bool
    /// True when the macOS shortcut is one Slick can turn off itself, through
    /// ``HotkeyService/turnOffSystemShortcut(for:)``: Spotlight's own two shortcuts. False for
    /// every other conflict.
    public var canTurnOff: Bool

    public init(owner: String, canOverride: Bool, isSystemShortcut: Bool = false, canTurnOff: Bool = false) {
        self.owner = owner
        self.canOverride = canOverride
        self.isSystemShortcut = isSystemShortcut
        self.canTurnOff = canTurnOff
    }
}

/// Why a hotkey could not be registered.
public enum HotkeyError: Error, Hashable, Sendable {
    case conflict([HotkeyConflict])
    /// The system returned an error code.
    case registrationFailed(code: Int32)
}
