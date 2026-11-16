import Foundation
import Kit

/// The feature's translation state on the main actor: the engine, the language list once it has
/// loaded, and the settings a plan reads. The page, root search and the settings pane share it.
///
/// The list loads off the main thread, once per activation. Nothing waits for it inside a
/// keystroke: root search shows a row that fills when it arrives, and a command awaits it.
final class Translator {
    let engine: any TranslationEngine
    let settings: FeatureSettings
    let clock: any ClockService
    /// Runs on the main actor when a new language list is in place, before the load that made it
    /// finishes, so whoever waits for the load sees what the list changed.
    var catalogInstalled: (@MainActor () -> Void)?

    /// The language list, nil until it has loaded.
    private(set) var catalog: LanguageCatalog?
    private var loading: Task<LanguageCatalog, Never>?

    init(engine: any TranslationEngine, settings: FeatureSettings, clock: any ClockService) {
        self.engine = engine
        self.settings = settings
        self.clock = clock
    }

    /// The locale titles are written in: the app's own.
    var display: Locale { clock.locale }

    /// The language list, or one with no languages, for places that cannot wait.
    var catalogOrEmpty: LanguageCatalog { catalog ?? .empty(display: display) }

    /// Starts loading the language list again and forgets the old one's load, as at activation.
    func reload() {
        loading?.cancel()
        loading = nil
        startLoading()
    }

    /// Starts loading the language list unless it is loading or loaded. The load puts the list in
    /// place on the main actor before it finishes, so whoever awaits it sees the list.
    func startLoading() {
        guard loading == nil else { return }
        let engine = engine
        let display = display
        loading = Task { [weak self] in
            let catalog = await Self.makeCatalog(engine: engine, display: display)
            if !Task.isCancelled, let self {
                self.catalog = catalog
                self.catalogInstalled?()
            }
            return catalog
        }
    }

    /// The language list, loading it first when needed.
    func loadedCatalog() async -> LanguageCatalog {
        if let catalog { return catalog }
        startLoading()
        guard let loading else { return catalogOrEmpty }
        return await loading.value
    }

    /// Waits for the list that is loading. For `waitUntilReady()`.
    func waitForCatalog() async {
        _ = await loading?.value
    }

    /// Stops a load that is running, as at deactivation.
    func cancel() {
        loading?.cancel()
        loading = nil
    }

    @concurrent private static func makeCatalog(engine: any TranslationEngine, display: Locale) async -> LanguageCatalog
    {
        let supported = await engine.supportedLanguages()
        let preferred = await engine.preferredLanguages()
        return LanguageCatalog.make(supported: supported, preferred: preferred, display: display)
    }

    // MARK: Plans

    /// The language the settings name, resolved against the list: Automatic or the stored one.
    func defaultTarget(in catalog: LanguageCatalog) -> LanguageTag? {
        catalog.resolve(settings[TranslateSettings.target])
    }

    /// The language the page's menu opens on: the one last picked, else the default.
    func menuTarget(in catalog: LanguageCatalog) -> LanguageTag? {
        catalog.resolveOptional(settings[TranslateSettings.lastTarget]) ?? defaultTarget(in: catalog)
    }

    /// Remembers a language picked in the page's menu.
    func rememberMenuTarget(_ tag: LanguageTag) {
        settings[TranslateSettings.lastTarget] = tag.identifier
    }

    /// What a request needs besides its text.
    ///
    /// - Parameters:
    ///   - target: The language asked for, or nil for the setting's.
    ///   - isExplicit: True when the user named the target for this text.
    ///   - hint: A language the text is probably in.
    func plan(
        target: LanguageTag?, isExplicit: Bool, hint: LanguageTag? = nil, catalog: LanguageCatalog
    ) -> TranslationPlan {
        TranslationPlan(
            catalog: catalog, target: target ?? defaultTarget(in: catalog), isExplicit: isExplicit,
            second: catalog.resolveOptional(settings[TranslateSettings.secondTarget]), hint: hint)
    }
}
