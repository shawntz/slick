import Kit

/// The feature's settings. `nonisolated`, so the index and search queues can read them too.
nonisolated enum FileSearchSettings {
    /// Files appear in root search below the other results.
    static let showsInRoot = SettingKey("showsInRoot", default: true)
    /// Folders searched besides the home folder, as absolute paths.
    static let extraFolders = SettingKey("extraFolders", default: [String]())
    /// Folders never searched, as absolute paths.
    static let excludedFolders = SettingKey("excludedFolders", default: [String]())
    /// Names skipped wherever they appear, and wildcard patterns hidden from results.
    static let excludedNames = SettingKey("excludedNames", default: [String]())
    /// Index names that start with a dot and files Finder hides.
    static let includesHidden = SettingKey("includesHidden", default: false)

    /// Protected places the user asked to search, by ``ProtectedPlace`` raw value. Set by the
    /// buttons in the pane and on the Search Files page, never shown as a control.
    static let includedPlaces = SettingKey("includedPlaces", default: [String]())
    /// Protected places the user asked not to search, even when Full Disk Access would allow it.
    static let turnedOffPlaces = SettingKey("turnedOffPlaces", default: [String]())
    /// Protected places whose folders could not be read. Kept so a refused folder is not read
    /// again, at the next launch or ever, until the user asks for it again.
    static let deniedPlaces = SettingKey("deniedPlaces", default: [String]())

    /// Every setting that changes what the index holds.
    static let scopeKeys: [AnySettingKey] = [
        extraFolders.erased, excludedFolders.erased, excludedNames.erased, includesHidden.erased,
        includedPlaces.erased, turnedOffPlaces.erased, deniedPlaces.erased,
    ]
}
