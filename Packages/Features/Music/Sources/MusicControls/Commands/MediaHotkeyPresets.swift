import Kit

/// Hotkey sets for the three transport commands. Settings offers them. Nothing is bound until the
/// user applies one, and Now Playing is left to the user.
nonisolated enum MediaHotkeyPresets {
    static let all = [functionKeys, controlOptionCommand]

    /// F7, F8 and F9 alone, the keys Apple keyboards print the media symbols on. They reach the
    /// launcher when the keys send function keys: with Fn held, or with the keys set to act as
    /// standard function keys. Settings allows F1 to F20 without a modifier.
    static let functionKeys = HotkeyPreset(
        id: "function-keys", name: Strings.Presets.functionKeys,
        bindings: [
            MediaCommandID.previous: KeyCombo(Key(code: 0x62)),  // F7
            MediaCommandID.playPause: KeyCombo(Key(code: 0x64)),  // F8
            MediaCommandID.next: KeyCombo(Key(code: 0x65)),  // F9
        ])

    /// Control-Option-Command with Space and the brackets: Space plays or pauses, the left bracket
    /// goes back and the right one skips ahead. Window Management's presets use the arrows with
    /// these modifiers, never these keys. Settings shows any conflict before it binds.
    static let controlOptionCommand = HotkeyPreset(
        id: "control-option-command", name: Strings.Presets.controlOptionCommand,
        bindings: [
            MediaCommandID.playPause: KeyCombo(.space, [.control, .option, .command]),
            MediaCommandID.previous: KeyCombo(Key(code: 0x21), [.control, .option, .command]),  // [
            MediaCommandID.next: KeyCombo(Key(code: 0x1E), [.control, .option, .command]),  // ]
        ])
}

/// The command IDs. Stable: aliases, hotkeys and presets are keyed by them.
nonisolated enum MediaCommandID {
    static let playPause = "play-pause"
    static let pause = "pause"
    static let next = "next-track"
    static let previous = "previous-track"
    static let nowPlaying = "now-playing"
}
