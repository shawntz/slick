import Foundation
import Kit

/// The feature's settings, stored as `translate.<name>`. Languages are stored by identifier, such
/// as "fr-Latn-FR", so a list the system changes later never shifts what was chosen.
nonisolated enum TranslateSettings {
    /// The language translations go into. Empty means Automatic: the user's first preferred
    /// language that the Mac offers.
    static let target = SettingKey("target", default: "")
    /// The language for text that is already in the first one. Empty means none.
    static let secondTarget = SettingKey("secondTarget", default: "")
    /// "translate <text>" and "tr <text>" in root search.
    static let keywords = SettingKey("keywords", default: true)
    /// The language last picked in Translate's menu, which the menu opens on. Empty until the user
    /// picks one, and emptied when the first language changes in settings.
    static let lastTarget = SettingKey("lastTarget", default: "")

    /// The keys whose change makes earlier answers stale.
    static let languageKeys = [target.erased, secondTarget.erased]
}

extension TranslateSettings {
    /// The feature's pane in the settings window. The language menus list the catalog's languages
    /// once it has loaded, and always the choice already stored.
    @MainActor static func pane(
        catalog: LanguageCatalog, settings: FeatureSettings,
        openLanguageSettings: @escaping @MainActor @Sendable (ActionContext) async throws -> Void
    ) -> SettingsPane {
        let languages = catalog.entries.map { (value: $0.tag.identifier, title: $0.title) }
        let automaticName = catalog.automaticTarget.map(catalog.title(of:))
        let targets =
            [(value: "", title: TranslateStrings.automatic(automaticName))]
            + withStored(settings[target], in: languages, catalog: catalog)
        let seconds =
            [(value: "", title: TranslateStrings.noSecondLanguage)]
            + withStored(settings[secondTarget], in: languages, catalog: catalog)
        return SettingsPane([
            SettingsSection(
                TranslateStrings.languagesSection,
                items: [
                    .picker(
                        TranslateStrings.targetPicker, key: target, options: targets, info: TranslateStrings.targetInfo),
                    .picker(
                        TranslateStrings.secondPicker, key: secondTarget, options: seconds,
                        info: TranslateStrings.secondInfo),
                ]),
            SettingsSection(
                TranslateStrings.rootSearchSection,
                items: [.toggle(TranslateStrings.keywordsToggle, key: keywords, info: TranslateStrings.keywordsInfo)]),
            SettingsSection(
                TranslateStrings.downloadsSection,
                items: [
                    .note(TranslateStrings.downloadsNote),
                    .button(
                        TranslateStrings.openLanguageSettings, info: TranslateStrings.openLanguageSettingsInfo,
                        run: openLanguageSettings),
                ]),
            SettingsSection(
                TranslateStrings.permissionsSection,
                items: [.permission(.accessibility, info: TranslateStrings.accessibilityInfo)]),
            SettingsSection(TranslateStrings.privacySection, items: [.note(TranslateStrings.privacyNote)]),
        ])
    }

    /// The languages, with a stored choice the list does not hold added at the end, so the menu
    /// always shows what is stored.
    private static func withStored(
        _ stored: String, in languages: [(value: String, title: String)], catalog: LanguageCatalog
    ) -> [(value: String, title: String)] {
        guard !stored.isEmpty, !languages.contains(where: { $0.value == stored }) else { return languages }
        return languages + [(value: stored, title: catalog.title(of: LanguageTag(stored)))]
    }
}
