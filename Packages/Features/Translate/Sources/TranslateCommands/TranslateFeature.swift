import Foundation
import Kit

/// Translate: translation with Apple's Translation framework and the languages installed on the
/// Mac. The feature sends nothing over the network itself and starts no download.
///
/// - Translate opens a page that translates the text in the search field into the language in
///   its menu, with the recognized language above the translation.
/// - Translate Selection reads the text selected in the app in front and opens the same page.
/// - "translate <text>" and "tr <text>", optionally ending in "to <language>", answer in root
///   search with a row that fills when the translation arrives.
/// - The feature never downloads a language. When a pair is not installed, the answer names the
///   language to download and opens Translation Languages in System Settings.
///
/// Every call into the system goes through ``TranslationEngine``: the Translation framework in the
/// app, a table of made-up phrases elsewhere. Activation loads the list of languages off the main
/// thread and starts its listeners; it translates nothing, reads no selection and asks for nothing.
public final class TranslateFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "translate", name: TranslateStrings.featureName, icon: TranslationRows.icon,
        summary: TranslateStrings.summary,
        permissions: [PermissionNeed(.accessibility, reason: TranslateStrings.accessibilityReason)])

    static let translateID = "translate"
    static let selectionID = "translate-selection"

    let context: FeatureContext
    let translator: Translator
    let pages: TranslatePages
    let provider: KeywordProvider
    public let declarationChanges: ChangeSignal? = ChangeSignal()
    private var listeners: [Task<Void, Never>] = []

    /// Does no I/O. The live engine touches nothing until activation asks for the language list.
    public init(context: FeatureContext) {
        self.context = context
        translator = Translator(
            engine: context.service(TranslationEngineKey.self), settings: context.settings, clock: context.clock)
        pages = TranslatePages(translator: translator)
        provider = KeywordProvider(pages: pages)
        // A new list fills root rows that waited for it and the menus in settings.
        translator.catalogInstalled = { [weak self] in
            self?.provider.refresh()
            self?.declarationChanges?.send()
        }
    }

    // MARK: Declarations

    public var commands: [Command] {
        [translateCommand, selectionCommand]
    }

    var translateCommand: Command {
        Command(
            id: Self.translateID, title: TranslateStrings.translateCommand, icon: TranslationRows.icon,
            keywords: TranslateStrings.translateKeywords, fallback: Fallback { TranslateStrings.fallback($0) },
            takesRootQueryOnTab: true
        ) { [pages] context in
            let typed = context.launch == .fallback || context.launch == .tabFromRoot
            return try await pages.open(text: typed ? context.query : "")
        }
    }

    /// Reads the selection, so a deep link may not start it: a web page could otherwise make the
    /// launcher read and show what is selected in the app in front.
    var selectionCommand: Command {
        Command(
            id: Self.selectionID, title: TranslateStrings.selectionCommand, icon: .symbol("text.cursor"),
            keywords: TranslateStrings.selectionKeywords, requires: [.accessibility], allowsDeepLinks: false
        ) { [pages] context in
            try await Self.translateSelection(context, pages: pages)
        }
    }

    public var liveProviders: [LiveProvider] {
        [.instant(provider)]
    }

    public var settingsPane: SettingsPane? {
        TranslateSettings.pane(catalog: translator.catalogOrEmpty, settings: context.settings) { context in
            try await TranslatePages.openLanguageSettings(context)
        }
    }

    /// Says so in settings when the Mac offers no languages at all.
    public var status: FeatureStatus? {
        guard let catalog = translator.catalog, catalog.entries.isEmpty else { return nil }
        return FeatureStatus(.warning, TranslateStrings.unavailableStatus, message: TranslateStrings.unavailableMessage)
    }

    // MARK: Lifecycle

    /// Returns at once. Loads the list of languages off the main thread, and follows the language
    /// settings. Nothing is translated, read or asked for.
    public func activate() async {
        stopListening()
        // Subscribe before any work starts, so no change is missed.
        let settingChanges = context.settings.changes(
            ofAny: TranslateSettings.languageKeys + [TranslateSettings.keywords.erased])
        translator.reload()
        listeners.append(
            Task { [weak self] in
                for await name in settingChanges {
                    self?.settingChanged(name)
                }
            })
    }

    public func deactivate() async {
        stopListening()
        translator.cancel()
        provider.stop()
    }

    /// Waits until the list of languages has loaded. Root search answers with a loading row
    /// before that, so scenarios, the self-test and benchmarks wait for it before they type.
    public func waitUntilReady() async {
        await translator.waitForCatalog()
    }

    private func settingChanged(_ name: String) {
        // A new first language in settings is what the menu opens on from now on.
        if name == TranslateSettings.target.name { context.settings[TranslateSettings.lastTarget] = "" }
        provider.reset()
        declarationChanges?.send()
    }

    private func stopListening() {
        for listener in listeners {
            listener.cancel()
        }
        listeners = []
    }

    // MARK: Selection

    /// Translate Selection: the text selected in the app in front, on the Translate page.
    static func translateSelection(_ context: ActionContext, pages: TranslatePages) async throws -> ActionOutcome {
        // The app refuses a link to this command. Should a link reach it anyway, it reads nothing.
        guard context.launch != .deeplink else { return try await pages.open(text: "") }
        guard context.permissions.isGranted(.accessibility) else { return .needsPermission(.accessibility) }
        let selection = await context.selection.currentSelection()
        guard case .text(let text) = selection else { return noSelection(context) }
        // Counting stops at the limit, so a huge selection is refused before anything reads it all.
        guard !TranslationText.exceeds(text, bytes: TranslationText.maximumBytes) else {
            throw ActionFailure(TranslateStrings.selectionTooLongTitle, message: TranslateStrings.tooLongMessage)
        }
        guard TranslationText.hasVisibleText(text) else { return noSelection(context) }
        return try await pages.open(text: text)
    }

    private static func noSelection(_ context: ActionContext) -> ActionOutcome {
        context.showToast(.failure(TranslateStrings.noSelectionTitle, message: TranslateStrings.noSelectionMessage))
        return .keepOpen
    }
}
