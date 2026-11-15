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
}

/// Something else that uses a key combination.
public struct HotkeyConflict: Hashable, Sendable {
    /// Who owns it, such as "Spotlight" or a command's title.
    public var owner: String
    /// True when Slick may take the combination over after asking the user.
    public var canOverride: Bool
    /// True when an enabled macOS keyboard shortcut holds the combination, such as Spotlight's.
    /// Slick can never take it over. The launcher hotkey alone may wait for the user to turn that
    /// shortcut off; every other hotkey is refused.
    public var isSystemShortcut: Bool

    public init(owner: String, canOverride: Bool, isSystemShortcut: Bool = false) {
        self.owner = owner
        self.canOverride = canOverride
        self.isSystemShortcut = isSystemShortcut
    }
}

/// Why a hotkey could not be registered.
public enum HotkeyError: Error, Hashable, Sendable {
    case conflict([HotkeyConflict])
    /// The system returned an error code.
    case registrationFailed(code: Int32)
}
