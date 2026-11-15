/// A feature's page in the settings window, described as data. The settings window draws it and
/// writes values through the settings service, so a feature sees changes through
/// ``FeatureSettings/changes(of:)``.
///
/// Per-command aliases, hotkeys and on/off switches, the feature's ``Feature/status`` and its
/// ``Feature/hotkeyPresets`` are added by the settings window; do not declare them here.
public struct SettingsPane: Sendable {
    public var sections: [SettingsSection]

    public init(_ sections: [SettingsSection]) {
        self.sections = sections
    }

    /// A pane with one untitled section.
    public init(items: [SettingsItem]) {
        self.sections = [SettingsSection(items: items)]
    }
}

/// A group of settings with an optional heading and footer.
public struct SettingsSection: Sendable {
    public var title: String?
    public var footer: String?
    public var items: [SettingsItem]

    public init(_ title: String? = nil, footer: String? = nil, items: [SettingsItem]) {
        self.title = title
        self.footer = footer
        self.items = items
    }
}

/// One row in a settings pane. Make one with the static factories.
public struct SettingsItem: Sendable {
    public var title: String
    /// Help text under the control.
    public var info: String?
    public var control: SettingsControl
    /// For a picker, whether choosing a value asks first. The settings window calls it with the
    /// stored value, or the key's default when the user never set one, and the value chosen. When
    /// it returns a confirmation, the window shows it and stores the choice only if the user goes
    /// ahead; otherwise the picker returns to the stored value. Set it through
    /// ``picker(_:key:options:info:confirm:)`` for a choice that deletes data at once, such as a
    /// shorter history.
    public var changeConfirmation: SettingChangeConfirmation?

    public init(title: String, info: String? = nil, control: SettingsControl) {
        self.title = title
        self.info = info
        self.control = control
    }

    /// A switch.
    public static func toggle(_ title: String, key: SettingKey<Bool>, info: String? = nil) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .toggle(key.erased))
    }

    /// A pop-up menu of fixed choices.
    public static func picker<Value: SettingValue>(
        _ title: String, key: SettingKey<Value>, options: [(value: Value, title: String)], info: String? = nil
    ) -> SettingsItem {
        let choices = options.map { SettingsOption(title: $0.title, value: $0.value.settingStorage) }
        return SettingsItem(title: title, info: info, control: .picker(key.erased, options: choices))
    }

    /// A pop-up menu over every case of a string enum, titled by a closure.
    public static func picker<Value: SettingValue & CaseIterable & RawRepresentable>(
        _ title: String, key: SettingKey<Value>, info: String? = nil, titles: (Value) -> String
    ) -> SettingsItem where Value.RawValue == String {
        picker(title, key: key, options: Value.allCases.map { ($0, titles($0)) }, info: info)
    }

    /// A one-line text field. For an API key or a token, use ``secret(_:name:placeholder:info:)``.
    public static func textField(
        _ title: String, key: SettingKey<String>, placeholder: String? = nil, info: String? = nil
    ) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .textField(key.erased, placeholder: placeholder))
    }

    /// A field drawn as dots whose value goes to the Keychain through ``FeatureSecrets``, never to
    /// settings. Read it with `context.secrets.value(for: name)`.
    public static func secret(_ title: String, name: String, placeholder: String? = nil, info: String? = nil)
        -> SettingsItem
    {
        SettingsItem(title: title, info: info, control: .secret(name: name, placeholder: placeholder))
    }

    /// A number with plus and minus buttons.
    public static func stepper(
        _ title: String, key: SettingKey<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil,
        info: String? = nil
    ) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .stepper(key.erased, range: range, step: step, unit: unit))
    }

    /// A hotkey recorder. The settings window checks conflicts while recording.
    public static func hotkey(_ title: String, key: SettingKey<KeyCombo?>, info: String? = nil) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .hotkey(key.erased))
    }

    /// A button that runs code, such as "Clear History", optionally after a confirmation. It runs like
    /// an action with ``LaunchSource/settings``: toasts show in the settings window, a thrown error
    /// shows a failure toast, and the context can ask questions or open file dialogs.
    public static func button(
        _ title: String, style: Action.Style = .regular, confirmation: Confirmation? = nil, info: String? = nil,
        run: @escaping @MainActor @Sendable (ActionContext) async throws -> Void
    ) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .button(style: style, confirmation: confirmation, run: run))
    }

    /// A list the user edits with add and remove buttons.
    public static func list(
        _ title: String, key: SettingKey<[String]>, itemKind: EditableListKind = .text, placeholder: String? = nil,
        info: String? = nil
    ) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .list(key.erased, itemKind: itemKind, placeholder: placeholder))
    }

    /// Checkboxes over values the feature supplies, such as the user's calendars. The window calls
    /// `options` each time it shows the pane and stores the chosen values.
    public static func multiSelect(
        _ title: String, key: SettingKey<[String]>, info: String? = nil,
        options: @escaping @MainActor @Sendable () async -> [SettingsChoice]
    ) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .multiSelect(key.erased, options: options))
    }

    /// One application, chosen with an app picker and stored by bundle ID.
    public static func application(_ title: String, key: SettingKey<String>, info: String? = nil) -> SettingsItem {
        SettingsItem(title: title, info: info, control: .application(key.erased))
    }

    /// A permission's live status with a Grant button that runs the host's grant flow, showing the
    /// reason from the manifest.
    public static func permission(_ permission: Permission, info: String? = nil) -> SettingsItem {
        SettingsItem(title: permission.displayName, info: info, control: .permission(permission))
    }

    /// Static explanatory text.
    public static func note(_ text: String) -> SettingsItem {
        SettingsItem(title: text, control: .note)
    }
}

/// The control a settings item draws.
public enum SettingsControl: Sendable {
    case toggle(AnySettingKey)
    case picker(AnySettingKey, options: [SettingsOption])
    case textField(AnySettingKey, placeholder: String?)
    case secret(name: String, placeholder: String?)
    case stepper(AnySettingKey, range: ClosedRange<Int>, step: Int, unit: String?)
    case hotkey(AnySettingKey)
    case button(
        style: Action.Style, confirmation: Confirmation?, run: @MainActor @Sendable (ActionContext) async throws -> Void
    )
    case list(AnySettingKey, itemKind: EditableListKind, placeholder: String?)
    case multiSelect(AnySettingKey, options: @MainActor @Sendable () async -> [SettingsChoice])
    case application(AnySettingKey)
    case permission(Permission)
    case note

    /// The setting the control edits, if any.
    public var key: AnySettingKey? {
        switch self {
        case .toggle(let key), .picker(let key, _), .textField(let key, _), .stepper(let key, _, _, _),
            .hotkey(let key), .list(let key, _, _), .multiSelect(let key, _), .application(let key):
            key
        case .secret, .button, .permission, .note:
            nil
        }
    }
}

/// One choice in a picker.
public struct SettingsOption: Hashable, Sendable {
    public var title: String
    public var value: SettingStorage

    public init(title: String, value: SettingStorage) {
        self.title = title
        self.value = value
    }
}

/// One checkbox in a multi-select, such as a calendar.
public struct SettingsChoice: Hashable, Sendable {
    /// The value stored when the box is checked.
    public var id: String
    public var title: String
    public var icon: Icon?

    public init(id: String, title: String, icon: Icon? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// What the entries of an editable list are, which decides how the user adds one.
public enum EditableListKind: Hashable, Sendable {
    /// Free text.
    case text
    /// Applications, stored by bundle ID and added with an app picker.
    case application
    /// Folders, stored as paths and added with a folder picker.
    case folder
}
