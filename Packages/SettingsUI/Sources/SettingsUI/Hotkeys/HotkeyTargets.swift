import Kit
import KitHosting

/// The hotkeys settings edits, each as a ``HotkeyTarget``.
enum HotkeyTargets {
    /// The launcher hotkey in ``HostSettings/launcherHotkey``. Taking a combination from one of the
    /// user's items clears that item's hotkey, so two bindings never share it. A combination a macOS
    /// shortcut holds is stored: the app binds it the moment the user turns that shortcut off.
    static func launcher(general: FeatureSettings, preferences: any ItemPreferences) -> HotkeyTarget {
        HotkeyTarget(
            title: "Launcher hotkey",
            read: { general[HostSettings.launcherHotkey] },
            conflicts: { combo in
                guard combo != general[HostSettings.launcherHotkey] else { return [] }
                return preferences.hotkeyConflicts(for: combo, excluding: nil)
            },
            write: { combo, replacing in
                if let combo, !replacing.isEmpty {
                    try releaseItems(holding: combo, preferences: preferences)
                }
                general[HostSettings.launcherHotkey] = combo
            },
            waitsForSystemShortcuts: true)
    }

    /// One item's hotkey through ``ItemPreferences``, which takes a combination over from another
    /// item and refuses conflicts that cannot be overridden.
    static func item(_ id: ItemID, title: String, preferences: any ItemPreferences) -> HotkeyTarget {
        HotkeyTarget(
            title: title,
            read: { preferences.hotkeys[id] },
            conflicts: { preferences.hotkeyConflicts(for: $0, excluding: id) },
            write: { combo, _ in try preferences.setHotkey(combo, for: id) })
    }

    /// A feature's own hotkey setting from its settings pane. The feature binds it; settings stores
    /// it and checks conflicts like any other.
    static func setting(
        _ key: AnySettingKey, title: String, settings: FeatureSettings, preferences: any ItemPreferences
    ) -> HotkeyTarget {
        let read: @MainActor () -> KeyCombo? = {
            KeyCombo?(settingStorage: settings.storage(of: key)) ?? nil
        }
        return HotkeyTarget(
            title: title,
            read: read,
            conflicts: { combo in
                guard combo != read() else { return [] }
                return preferences.hotkeyConflicts(for: combo, excluding: nil)
            },
            write: { combo, replacing in
                if let combo, !replacing.isEmpty {
                    try releaseItems(holding: combo, preferences: preferences)
                }
                settings.write(combo.settingStorage, for: key)
            })
    }

    /// Clears the hotkey of every item that holds `combo`.
    private static func releaseItems(holding combo: KeyCombo, preferences: any ItemPreferences) throws {
        for (id, held) in preferences.hotkeys where held == combo {
            try preferences.setHotkey(nil, for: id)
        }
    }
}
