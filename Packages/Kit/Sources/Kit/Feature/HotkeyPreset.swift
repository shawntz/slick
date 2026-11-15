/// A set of hotkeys for a feature's own commands that the user applies in one step, such as window
/// layout shortcuts that match another app's.
///
/// Settings lists a feature's presets. Applying one shows the conflicts with hotkeys the user already
/// has, then binds every command in the preset as if the user had recorded each hotkey. Nothing is
/// bound until the user applies a preset.
public struct HotkeyPreset: Hashable, Sendable {
    /// Unique within the feature.
    public var id: String
    /// The name in settings, such as "Rectangle".
    public var name: String
    /// Hotkeys by command ID. Every key must be one of the feature's command IDs.
    public var bindings: [String: KeyCombo]

    public init(id: String, name: String, bindings: [String: KeyCombo]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }
}
