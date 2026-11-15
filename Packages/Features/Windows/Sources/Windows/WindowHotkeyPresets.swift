import Kit

/// Shortcut sets that match the window tools people already know, so someone switching keeps their
/// habits. Settings offers them. Nothing is bound until the user applies one.
nonisolated enum WindowHotkeyPresets {
    static let all = [rectangle, spectacle]

    /// Control-Option with arrows and letters. Rectangle ships these defaults, and Magnet uses the
    /// same keys for the layouts both offer.
    static let rectangle = HotkeyPreset(
        id: "rectangle", name: Strings.rectanglePreset,
        bindings: [
            "left-half": KeyCombo(.leftArrow, [.control, .option]),
            "right-half": KeyCombo(.rightArrow, [.control, .option]),
            "top-half": KeyCombo(.upArrow, [.control, .option]),
            "bottom-half": KeyCombo(.downArrow, [.control, .option]),
            "top-left-quarter": KeyCombo(.u, [.control, .option]),
            "top-right-quarter": KeyCombo(.i, [.control, .option]),
            "bottom-left-quarter": KeyCombo(.j, [.control, .option]),
            "bottom-right-quarter": KeyCombo(.k, [.control, .option]),
            "first-third": KeyCombo(.d, [.control, .option]),
            "center-third": KeyCombo(.f, [.control, .option]),
            "last-third": KeyCombo(.g, [.control, .option]),
            "first-two-thirds": KeyCombo(.e, [.control, .option]),
            "last-two-thirds": KeyCombo(.t, [.control, .option]),
            "maximize": KeyCombo(.return, [.control, .option]),
            "maximize-height": KeyCombo(.upArrow, [.control, .option, .shift]),
            "make-smaller": KeyCombo(.minus, [.control, .option]),
            "make-larger": KeyCombo(.equal, [.control, .option]),
            "center": KeyCombo(.c, [.control, .option]),
            "restore": KeyCombo(.delete, [.control, .option]),
            "next-display": KeyCombo(.rightArrow, [.control, .option, .command]),
            "previous-display": KeyCombo(.leftArrow, [.control, .option, .command]),
        ])

    /// Option-Command with arrows for halves, Control-Command for corners, as Spectacle shipped.
    static let spectacle = HotkeyPreset(
        id: "spectacle", name: Strings.spectaclePreset,
        bindings: [
            "left-half": KeyCombo(.leftArrow, [.option, .command]),
            "right-half": KeyCombo(.rightArrow, [.option, .command]),
            "top-half": KeyCombo(.upArrow, [.option, .command]),
            "bottom-half": KeyCombo(.downArrow, [.option, .command]),
            "top-left-quarter": KeyCombo(.leftArrow, [.control, .command]),
            "top-right-quarter": KeyCombo(.rightArrow, [.control, .command]),
            "bottom-left-quarter": KeyCombo(.leftArrow, [.control, .shift, .command]),
            "bottom-right-quarter": KeyCombo(.rightArrow, [.control, .shift, .command]),
            "maximize": KeyCombo(.f, [.option, .command]),
            "center": KeyCombo(.c, [.option, .command]),
            "make-larger": KeyCombo(.rightArrow, [.control, .option, .shift]),
            "make-smaller": KeyCombo(.leftArrow, [.control, .option, .shift]),
            "next-display": KeyCombo(.rightArrow, [.control, .option, .command]),
            "previous-display": KeyCombo(.leftArrow, [.control, .option, .command]),
            "restore": KeyCombo(.z, [.option, .command]),
        ])
}
