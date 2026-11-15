import Kit

/// A setting value as stored, for writing through a feature's ``FeatureSettings`` when only the
/// untyped key from its settings pane is known.
struct RawSetting: SettingValue {
    var storage: SettingStorage

    init(_ storage: SettingStorage) {
        self.storage = storage
    }

    init?(settingStorage: SettingStorage) {
        storage = settingStorage
    }

    var settingStorage: SettingStorage { storage }
}

extension FeatureSettings {
    /// Writes a value under an untyped key. Nil forgets it, so reads return the default.
    func write(_ storage: SettingStorage?, for key: AnySettingKey) {
        let typed = SettingKey(key.name, default: RawSetting(key.defaultValue))
        if let storage {
            self[typed] = RawSetting(storage)
        } else {
            reset(typed)
        }
    }
}
