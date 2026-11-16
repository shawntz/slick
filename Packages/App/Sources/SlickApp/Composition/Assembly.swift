import AppKit
import Foundation
import Host
import Kit
import KitHosting
import LauncherUI
import Platform
import Root
import SettingsUI
import os

/// The composition root: every part of the launcher, made and connected for one run environment.
///
/// Making it builds the graph and starts nothing that listens to the Mac except Platform's own
/// monitors in the live environment. ``start()`` registers and activates the features and binds
/// the launcher hotkey; ``shutdown()`` undoes all of it and writes what is pending.
///
/// The order matters:
///
/// 1. Platform's services for the environment, over the data folder.
/// 2. Kit's `Services` from Platform's, with forwarders for the usage service and the fuzzy index,
///    because Root, which makes those two, needs the feature runtime first.
/// 3. Host's feature runtime over those services.
/// 4. Root search over the runtime, Platform's system context, the settings and the clock. Its
///    engine opens off the main thread; a second engine on the same folder falls back to memory.
/// 5. The forwarders point at Root.
/// 6. The theme store, the panel over Root and Platform's icons, the launcher hotkey, the settings
///    window's dependencies, which read the hotkey's state, and Platform's hooks.
@MainActor final class Assembly {
    /// What one run is made of.
    struct Configuration {
        var environment: RunEnvironment
        /// The data folder. Every file the run writes goes under it.
        var dataRoot: URL
        var registrations: [FeatureRegistration] = Features.registrations
        /// Root search's folder. Nil puts it in the data folder.
        var rootStorage: RootStoragePaths?
        /// Catalog sources Root owns, such as the bench's synthetic catalog.
        var builtInSources: [any CatalogSource] = []
        /// Light priors for the first run. Only the live app passes them.
        var firstRunSeeds: (@Sendable () async -> [LearningSeed])?
        /// Replaces the workspace, as scenarios do to record what features open.
        var workspace: ((any WorkspaceService) -> any WorkspaceService)?
        /// Replaces the hotkey service, as tests do.
        var hotkeys: (any HotkeyService)?
        /// Replaces the clock every package reads, as scenarios do to move time.
        var clock: (any ClockService)?
        /// Replaces the file dialogs, as scenarios do to hand back made-up files.
        var fileDialogs: (any FileDialogService)?
        /// Makes the icons the panel and settings draw in place of Platform's, as a scenario that
        /// shows the system's own apps does.
        var icons: (@MainActor (PlatformServices) -> any IconProvider)?
        /// False skips the panel, for headless runs that only query root search.
        var makesPanel = true
        /// The surface the panel drives. Tests pass one placed off every screen.
        var surface: LauncherSurface?
        /// True lets settings show its window. Only the live launcher does.
        var showsWindows = false
    }

    let configuration: Configuration
    let platform: PlatformServices
    let services: Services
    let runtime: FeatureRuntime
    let root: RootSearch
    let themes: ThemeStore
    let panel: PanelController?
    let settings: SettingsOpener
    let links: DeepLinkRouter
    let hotkey: LauncherHotkey
    /// The services a scenario checks.
    let recordingWorkspace: RecordingWorkspace?
    /// HUDs outside the live app, which are written down instead of shown.
    let recordingHUD: RecordingHUD?
    /// The file dialogs a scenario queues answers for.
    let scenarioFileDialogs: ScenarioFileDialogs?
    /// The clock a scenario moves, when the run has one.
    var scenarioClock: ScenarioClock? { services.clock as? ScenarioClock }

    private let usage = LateUsageService()
    private let fuzzyIndex = LateFuzzyIndexService()
    private var watchers: [Task<Void, Never>] = []
    private var started = false
    private let log = KitLog.logger(category: "app.assembly")

    var environment: RunEnvironment { configuration.environment }
    var general: FeatureSettings { HostSettings.settings(services.settings) }

    init(_ configuration: Configuration) {
        self.configuration = configuration
        let environment = configuration.environment
        let platform = PlatformServices(.init(environment: environment, dataRoot: configuration.dataRoot))
        self.platform = platform

        var services = platform.services(usage: usage, fuzzyIndex: fuzzyIndex)
        if let makeWorkspace = configuration.workspace { services.workspace = makeWorkspace(services.workspace) }
        if let hotkeys = configuration.hotkeys { services.hotkeys = hotkeys }
        if let clock = configuration.clock { services.clock = clock }
        if let fileDialogs = configuration.fileDialogs { services.fileDialogs = fileDialogs }
        self.services = services
        recordingWorkspace = services.workspace as? RecordingWorkspace
        scenarioFileDialogs = services.fileDialogs as? ScenarioFileDialogs

        let hostFolder = platform.storage.dataDirectory(for: Self.hostFolderName)
        let runtime = FeatureRuntime(services: services, environment: environment, dataDirectory: hostFolder)
        self.runtime = runtime

        let root = RootSearch(
            RootConfiguration(
                directory: runtime, preferences: runtime.preferences, systemContext: platform.systemContext,
                settings: services.settings, clock: services.clock,
                storage: configuration.rootStorage ?? RootStoragePaths(storage: platform.storage),
                environment: environment, builtInSources: configuration.builtInSources,
                firstRunSeeds: configuration.firstRunSeeds))
        self.root = root
        usage.connect(root.usage)
        fuzzyIndex.connect(root.fuzzyIndex)

        let general = HostSettings.settings(services.settings)
        themes = ThemeStore(
            folder: configuration.dataRoot.appending(path: Self.themesFolderName, directoryHint: .isDirectory),
            selecting: general[HostSettings.themeName])

        let hud = environment.touchesRealSystem ? nil : RecordingHUD()
        recordingHUD = hud
        let icons = configuration.icons?(platform) ?? platform.icons
        let panel =
            configuration.makesPanel
            ? PanelController(
                runtime: runtime, rootSource: root, icons: icons, themes: themes,
                surface: configuration.surface, hud: hud) : nil
        self.panel = panel

        let hotkey = LauncherHotkey(
            hotkeys: services.hotkeys, settings: services.settings, retrySignal: runtime.preferences.changes,
            clock: services.clock, press: { [weak panel] in panel?.toggle() })
        self.hotkey = hotkey

        let dependencies = SettingsDependencies(
            services: services, features: runtime, preferences: runtime.preferences, learning: root.inspector,
            icons: icons, loginItem: platform.loginItem, themes: themes, dataDirectory: configuration.dataRoot,
            about: AboutInfo.fromMainBundle(links: ProjectLinks.about),
            lookUpItem: { [weak root] id in root?.row(for: id) }, launcherHotkey: hotkey)
        settings = SettingsOpener(
            showsWindows: configuration.showsWindows, onOpen: { [weak hotkey] in hotkey?.checkNow() },
            makeController: { SettingsController(dependencies: dependencies) },
            makeOnboarding: { OnboardingController(dependencies: dependencies) })
        self.dependencies = dependencies
        links = DeepLinkRouter(runtime: runtime, panel: panel, settings: settings)

        connectHooks()
    }

    /// What the settings window and onboarding are made from.
    let dependencies: SettingsDependencies

    /// The folder for Host's `preferences.json`, under the data folder's `Features`. It contains a
    /// ".", which no feature ID may, so no feature can share it.
    static let hostFolderName = "app.host"
    /// The folder of user theme files, directly in the data folder so people can find it.
    static let themesFolderName = "Themes"

    // MARK: Hooks

    private func connectHooks() {
        hotkey.onBoundAfterWait = { [weak panel] combo in
            panel?.showHUD(.success(SpotlightShortcutGuide.nowOpens(combo)))
        }
        let settings = settings
        panel?.onOpenSettings = { [weak panel] in
            panel?.dismiss()
            settings.open()
        }
        let closer: @MainActor @Sendable () -> Void = { [weak panel] in panel?.dismiss() }
        platform.pasteboard.setPanelCloser(closer)
        let runtime = runtime
        platform.textExpansion.setCommandRunner { [weak runtime] id, arguments in
            await MainActor.run {
                _ = runtime?.pipeline.runCommand(id, arguments: arguments, launch: .textExpansion)
            }
        }
    }

    /// Gives the pasteboard the history reader of the feature that provides clipboard history,
    /// while that feature is on.
    func applyProvidedServices() {
        var reader: (any ClipboardHistoryReader)?
        for entry in runtime.enabledFeatures {
            for service in entry.provides {
                switch service {
                case .clipboardHistory(let provided): reader = reader ?? provided
                }
            }
        }
        platform.pasteboard.setHistoryReader(reader)
        historyReader = reader
    }

    /// The clipboard history of the feature that provides it, while that feature is on.
    private(set) var historyReader: (any ClipboardHistoryReader)?

    /// True while a feature's clipboard history answers the pasteboard's recent text.
    var hasHistoryReader: Bool { historyReader != nil }

    // MARK: Lifecycle

    /// Starts Platform's monitors, registers and activates the features, connects the services
    /// they provide and binds the launcher hotkey. Prewarms the panel when `prewarm` is true; only
    /// runs that show the panel should.
    func start(prewarm: Bool) async {
        guard !started else { return }
        started = true
        platform.start()
        await runtime.start(configuration.registrations)
        applyProvidedServices()
        let changes = runtime.changes.stream()
        watchers.append(
            Task { [weak self] in
                for await _ in changes { self?.applyProvidedServices() }
            })
        hotkey.start()
        if prewarm {
            GlassPanel.installEditMenu()
            panel?.prewarm()
        }
    }

    /// Returns once every active feature finished the work its activation started and root search
    /// loaded every catalog source and opened its engine. Scenarios, the self-test and benchmarks
    /// wait for it before they type. The live launcher never does.
    func ready() async {
        await runtime.waitUntilFeaturesAreReady()
        await root.ready()
    }

    /// Unbinds the hotkey, deactivates the features, writes what root search learned, lets the
    /// engine go and stops Platform. Safe to call more than once.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for watcher in watchers { watcher.cancel() }
        watchers = []
        hotkey.stop()
        panel?.dismiss()
        if !environment.touchesRealSystem { panel?.surface.panel.orderOut(nil) }
        await runtime.deactivateAll()
        await root.flush()
        await root.shutdown()
        platform.pasteboard.setPanelCloser(nil)
        platform.pasteboard.setHistoryReader(nil)
        platform.textExpansion.setCommandRunner(nil)
        platform.stop()
    }

    private var isShutDown = false
}
