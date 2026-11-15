/// A typed key for one setting, with its default.
///
/// Declare keys as static constants in a `nonisolated enum`, read them through ``FeatureSettings``,
/// and list them in the ``SettingsPane`` so the user can change them. A key declared on the feature
/// class belongs to the main actor in a feature package, and a background task could not read it.
///
/// ```swift
/// nonisolated enum EmojiSettings {
///     static let skinTone = SettingKey("skinTone", default: SkinTone.none)
/// }
/// let tone = context.settings[EmojiSettings.skinTone]
/// ```
public struct SettingKey<Value: SettingValue>: Sendable {
    /// Unique within the feature. Stored as `<feature id>.<name>`.
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }

    /// The key without its type, for settings panes.
    public var erased: AnySettingKey {
        AnySettingKey(name: name, defaultValue: defaultValue.settingStorage)
    }
}

/// A setting key without its value type, as settings panes carry it.
public struct AnySettingKey: Hashable, Sendable {
    public let name: String
    public let defaultValue: SettingStorage

    public init(name: String, defaultValue: SettingStorage) {
        self.name = name
        self.defaultValue = defaultValue
    }
}
