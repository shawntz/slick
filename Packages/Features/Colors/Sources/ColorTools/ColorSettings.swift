import Kit

/// The feature's settings, stored as `colors.<name>`. `nonisolated`, so code off the main actor can
/// read them.
nonisolated enum ColorSettings {
    /// The format Return copies, Pick Color copies, and typed colors show first.
    static let defaultFormat = SettingKey("defaultFormat", default: ColorFormat.hex)
    /// Uppercase or lowercase hex digits, in hex and in CSS variables.
    static let hexCase = SettingKey("hexCase", default: HexCase.uppercase)
    /// The most colors the history keeps, pinned colors aside.
    static let historyLimit = SettingKey("historyLimit", default: 100)
    /// Whether root search converts typed colors and answers contrast questions.
    static let convertsTypedColors = SettingKey("convertsTypedColors", default: true)

    /// The choices offered for the history's size.
    static let historyLimits = [25, 50, 100, 250, 500, 1000]
    /// The bounds applied to a stored history size, whatever wrote it.
    static let historyLimitRange = 1...10_000
}

extension ColorSettings {
    /// The feature's pane in the settings window.
    @MainActor static func pane(history: ColorHistory) -> SettingsPane {
        SettingsPane([
            SettingsSection(
                ColorStrings.formatsSection,
                items: [
                    .picker(
                        ColorStrings.defaultFormat, key: defaultFormat, info: ColorStrings.defaultFormatInfo,
                        titles: ColorStrings.defaultFormatOption),
                    .picker(ColorStrings.hexCase, key: hexCase, titles: ColorStrings.hexCaseOption),
                ]),
            SettingsSection(
                ColorStrings.rootSection,
                items: [
                    .toggle(
                        ColorStrings.convertsTypedColors, key: convertsTypedColors,
                        info: ColorStrings.convertsTypedColorsInfo)
                ]),
            SettingsSection(
                ColorStrings.historySection, footer: ColorStrings.historyFooter(appName: Brand.name),
                items: [
                    .picker(
                        ColorStrings.historyLimit, key: historyLimit,
                        options: historyLimits.map { ($0, ColorStrings.historyLimitOption($0)) },
                        info: ColorStrings.historyLimitInfo, confirm: limitConfirmation),
                    .button(
                        ColorStrings.clearHistory, style: .destructive, confirmation: ColorActions.clearConfirmation
                    ) { context in
                        await history.clear()
                        context.showToast(.success(ColorStrings.clearedToast))
                    },
                ]),
        ])
    }

    /// Asks before a smaller history size, which deletes the oldest colors at once. A larger size
    /// loses nothing and asks nothing.
    static func limitConfirmation(stored: Int, chosen: Int) -> Confirmation? {
        let current = min(max(stored, historyLimitRange.lowerBound), historyLimitRange.upperBound)
        guard chosen < current else { return nil }
        return Confirmation(
            ColorStrings.limitQuestion(chosen), message: ColorStrings.limitMessage(chosen),
            confirmTitle: ColorStrings.limitConfirm, isDestructive: true)
    }
}
