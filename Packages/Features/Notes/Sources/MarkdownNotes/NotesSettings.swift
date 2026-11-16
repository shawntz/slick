import Kit

/// The feature's settings. Stored as `notes.<name>`.
nonisolated enum NotesSettings {
    /// Whether note titles join root search's catalog. Off by default: root search is where people
    /// type in front of others, a title there can show private words for an unrelated query, and up
    /// to 5,000 titles would weigh on every keystroke. Search Notes and quick capture work either way.
    static let showsInRootSearch = SettingKey("showsInRootSearch", default: false)

    /// Whether `note` and some text in root search offers to save a note. On by default: it shows
    /// only after the keyword and a space, and saves nothing until the user presses Return.
    static let quickCapture = SettingKey("quickCapture", default: true)

    /// The folder the user chose for notes, as an absolute path. Empty means the default folder in
    /// the feature's data folder. A value that is not an absolute path reads as empty.
    static let folder = SettingKey("folder", default: "")

    /// The guarded folder the feature has read after the user chose it, as an absolute path. A
    /// guarded folder is read at activation only when it matches, so macOS never asks at launch for
    /// a folder whose first read the user did not start.
    static let confirmedFolder = SettingKey("confirmedFolder", default: "")
}
