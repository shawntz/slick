import Kit

/// The feature's settings, stored as `dictionary.<name>`. The defaults change nothing in the main
/// search until the user types a keyword, and Return never pastes unless the user chooses it.
nonisolated enum DefineSettings {
    /// "define <word>" and "spell <word>" in root search, as in Alfred.
    static let keywords = SettingKey("keywords", default: true)
    /// A definition under the other results when the query is a single word.
    static let singleWords = SettingKey("singleWords", default: false)
    /// What Return does on a spelling suggestion.
    static let spellingReturn = SettingKey("spellingReturn", default: SpellingReturn.copy)
}

/// What Return does on a spelling suggestion. Command-Return does the other.
nonisolated enum SpellingReturn: String, CaseIterable, Sendable, SettingValue {
    case copy, paste
}

extension DefineSettings {
    /// The feature's pane in the settings window.
    @MainActor static func pane(openDictionary: @escaping @MainActor @Sendable (ActionContext) async throws -> Void)
        -> SettingsPane
    {
        SettingsPane([
            SettingsSection(
                DefineStrings.mainSearchSection,
                items: [
                    .toggle(DefineStrings.keywordsToggle, key: keywords, info: DefineStrings.keywordsInfo),
                    .toggle(DefineStrings.singleWordsToggle, key: singleWords, info: DefineStrings.singleWordsInfo),
                ]),
            SettingsSection(
                DefineStrings.spellingSection,
                items: [
                    .picker(DefineStrings.spellingReturn, key: spellingReturn, info: DefineStrings.spellingReturnInfo) {
                        $0 == .copy ? DefineStrings.spellingReturnCopies : DefineStrings.spellingReturnPastes
                    },
                    .permission(.accessibility, info: DefineStrings.accessibilityInfo),
                ]),
            SettingsSection(
                DefineStrings.dictionariesSection,
                items: [
                    .note(DefineStrings.sourcesNote),
                    .button(DefineStrings.openDictionary, info: DefineStrings.openDictionaryInfo, run: openDictionary),
                ]),
            SettingsSection(DefineStrings.privacySection, items: [.note(DefineStrings.privacyNote)]),
        ])
    }
}
