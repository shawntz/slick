import Kit

/// The feature's settings. `nonisolated`, so the live subtitle can read them off the main thread.
nonisolated enum MediaSettings {
    /// The player the commands offer to open when none runs, and control when both run and
    /// neither plays. Music by default, since every Mac has it.
    static let preferredPlayer = SettingKey("preferredPlayer", default: Player.music)

    /// Outside the live launcher only: the bundle IDs of the simulated players a scenario quit,
    /// separated by commas. The live players never read it, and settings never shows it.
    static let simulatedQuit = SettingKey("simulatedQuit", default: "")
}
