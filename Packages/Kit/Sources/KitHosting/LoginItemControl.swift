/// Whether the app opens at login.
///
/// Platform implements it with the system's login item service. SettingsUI shows it as a switch.
@MainActor public protocol LoginItemControl: AnyObject, Sendable {
    /// True when the app is registered to open at login and the user allows it.
    var isEnabled: Bool { get }

    /// Registers or unregisters the app as a login item. Call it only from the user's switch: the
    /// system may show a notification. Throws when the system refuses.
    func setEnabled(_ enabled: Bool) throws
}
