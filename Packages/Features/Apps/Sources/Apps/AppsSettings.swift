import Kit

/// The feature's settings. `nonisolated`, so code off the main actor can read them too.
nonisolated enum AppsSettings {
    /// More folders to scan for apps, as paths, each read two levels deep.
    static let extraFolders = SettingKey("extraFolders", default: [String]())
    /// Bundle IDs of apps that never show in root search.
    static let hiddenApps = SettingKey("hiddenApps", default: [String]())
    /// Whether System Settings panes and their sections show in root search.
    static let showsSettingsPanes = SettingKey("showsSettingsPanes", default: true)
    /// Bundle IDs of apps that Quit All Applications leaves running. Finder by default: quitting it
    /// only makes it start again.
    static let keepRunning = SettingKey("keepRunning", default: ["com.apple.finder"])
}
