import Foundation
import Kit

/// Makes the feature's page and the actions of every row, so a translation behaves the same in
/// the page and in root search. Actions are built from a row's payload alone.
final class TranslatePages {
    /// Translation Languages in System Settings, where the user downloads languages. It is the
    /// link the system's own translation extension opens for the same purpose.
    nonisolated static let languageSettingsLink =
        "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"

    /// Swap Languages, as in other translators.
    nonisolated static let swapShortcut = KeyCombo(.s, [.shift, .command])

    let translator: Translator

    init(translator: Translator) {
        self.translator = translator
    }

    // MARK: Page

    /// The Translate page: the text in the search field, the target in the menu, the translation
    /// in the detail. The menu opens on `target`, else on the language last picked, else on the
    /// default.
    ///
    /// - Parameters:
    ///   - text: Text already in the search field.
    ///   - target: The language the menu opens on, as after Swap Languages.
    ///   - hint: A language the text is probably in.
    func page(text: String, catalog: LanguageCatalog, target: LanguageTag? = nil, hint: LanguageTag? = nil) -> Page {
        let selected = target.flatMap { catalog.entry($0.identifier)?.tag } ?? translator.menuTarget(in: catalog)
        let options = catalog.entries.map { FilterOption(id: $0.tag.identifier, title: $0.title) }
        let dropdown = FilterDropdown(
            title: TranslateStrings.dropdownTitle, options: options, defaultID: selected?.identifier,
            remembersSelection: false)
        return .list(
            ListPage(
                TranslateList(pages: self, catalog: catalog, hint: hint),
                searchPlaceholder: TranslateStrings.searchPlaceholder,
                filter: dropdown, showsDetail: true,
                emptyState: EmptyState(
                    icon: TranslationRows.icon, title: TranslateStrings.typeTextTitle,
                    message: TranslateStrings.typeTextMessage),
                initialQuery: text))
    }

    /// The page for a command: waits for the language list, and fails when the Mac has none.
    func open(text: String) async throws -> ActionOutcome {
        let catalog = await translator.loadedCatalog()
        guard !catalog.entries.isEmpty else {
            throw ActionFailure(TranslateStrings.unavailableTitle, message: TranslateStrings.unavailableMessage)
        }
        return .push(page(text: text, catalog: catalog))
    }

    // MARK: Actions

    /// A row's actions, from its payload alone. In root search a row also opens the page.
    func actions(for row: Row, place: RowPlace) -> [Action] {
        guard let item = try? row.payload?.decode(TranslationRow.self) else { return [] }
        let openPage = place == .root ? [openInTranslate(item)] : []
        switch item.outcome {
        case .translated(let source, let target, let text):
            return [
                Action.copy(text, title: TranslateStrings.copyTranslation, hud: TranslateStrings.copiedTranslation)
                    .with(id: "copy-translation"),
                Action.paste(text, title: TranslateStrings.pasteTranslation, shortcut: .secondaryAction)
                    .with(id: "paste-translation"),
                swap(translation: text, source: source, target: target, place: place),
                copyOriginal(item.original),
            ] + openPage
        case .needsDownload:
            return [openLanguageSettings()] + openPage + [copyOriginal(item.original)]
        case nil, .tooLong:
            return openPage + [copyOriginal(item.original)]
        case .unsupportedLanguage, .unsupportedPair, .alreadyIn, .notRecognized, .unavailable, .failed:
            return [copyOriginal(item.original)] + openPage
        }
    }

    /// Opens the page with the translation as the text and the languages the other way round.
    func swap(translation: String, source: LanguageTag, target: LanguageTag, place: RowPlace) -> Action {
        Action(
            TranslateStrings.swapLanguages, id: "swap-languages", icon: .symbol("arrow.left.arrow.right"),
            shortcut: Self.swapShortcut
        ) { [self] _ in
            let catalog = await translator.loadedCatalog()
            if catalog.entry(source.identifier) != nil { translator.rememberMenuTarget(source) }
            let page = page(text: translation, catalog: catalog, target: source, hint: target)
            return place == .page ? .replace(page) : .push(page)
        }
    }

    func copyOriginal(_ original: String) -> Action {
        Action.copy(
            original, title: TranslateStrings.copyOriginal, hud: TranslateStrings.copiedOriginal, shortcut: .copy
        )
        .with(id: "copy-original")
    }

    /// Opens Translation Languages in System Settings through the workspace service. The feature
    /// never downloads a language itself.
    func openLanguageSettings() -> Action {
        Action(TranslateStrings.openLanguageSettings, id: "open-language-settings", icon: TranslationRows.downloadIcon)
        {
            context in
            try await Self.openLanguageSettings(context)
            return .close()
        }
    }

    /// Opens the root row's text on the page, with the language it asked for.
    func openInTranslate(_ item: TranslationRow) -> Action {
        Action(TranslateStrings.openInTranslate, id: "open-in-translate", icon: TranslationRows.icon, shortcut: .open) {
            [self] _ in
            let catalog = await translator.loadedCatalog()
            guard !catalog.entries.isEmpty else {
                throw ActionFailure(TranslateStrings.unavailableTitle, message: TranslateStrings.unavailableMessage)
            }
            return .push(page(text: item.original, catalog: catalog, target: item.requested))
        }
    }

    /// Opens Translation Languages in System Settings.
    static func openLanguageSettings(_ context: ActionContext) async throws {
        guard let url = URL(string: languageSettingsLink) else { return }
        try await context.workspace.open(url)
    }
}
