/// Decides whether a new value of a setting asks first: the stored value and the value chosen, as
/// stored. Nil goes ahead without a question.
public typealias SettingChangeConfirmation =
    @MainActor @Sendable (_ stored: SettingStorage, _ chosen: SettingStorage) -> Confirmation?

extension SettingsItem {
    /// A pop-up menu of fixed choices that asks before it stores a choice that `confirm` returns a
    /// confirmation for. Use it for a choice that deletes data at once, such as a shorter history,
    /// and return nil for a choice that loses nothing, such as a longer one. `confirm` receives the
    /// stored value, or the key's default when the stored one is missing or of another type.
    public static func picker<Value: SettingValue>(
        _ title: String, key: SettingKey<Value>, options: [(value: Value, title: String)], info: String? = nil,
        confirm: @escaping @MainActor @Sendable (_ stored: Value, _ chosen: Value) -> Confirmation?
    ) -> SettingsItem {
        var item = picker(title, key: key, options: options, info: info)
        item.changeConfirmation = { stored, chosen in
            guard let chosen = Value(settingStorage: chosen) else { return nil }
            return confirm(Value(settingStorage: stored) ?? key.defaultValue, chosen)
        }
        return item
    }

    /// A pop-up menu over every case of a string enum, titled by a closure, that asks before it
    /// stores a choice that `confirm` returns a confirmation for.
    public static func picker<Value: SettingValue & CaseIterable & RawRepresentable>(
        _ title: String, key: SettingKey<Value>, info: String? = nil, titles: (Value) -> String,
        confirm: @escaping @MainActor @Sendable (_ stored: Value, _ chosen: Value) -> Confirmation?
    ) -> SettingsItem where Value.RawValue == String {
        picker(title, key: key, options: Value.allCases.map { ($0, titles($0)) }, info: info, confirm: confirm)
    }

    /// Whether choosing `chosen` asks first, with the stored value as the settings service holds it.
    /// A missing stored value reads as the key's default. Nil for an item that never asks.
    @MainActor public func confirmation(choosing chosen: SettingStorage, stored: SettingStorage?) -> Confirmation? {
        guard let changeConfirmation, let key = control.key, chosen != (stored ?? key.defaultValue) else {
            return nil
        }
        return changeConfirmation(stored ?? key.defaultValue, chosen)
    }
}
