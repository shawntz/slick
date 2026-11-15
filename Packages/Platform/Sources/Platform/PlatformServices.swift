import AppKit
import Foundation
import Kit
import KitHosting

/// Every service Platform implements, built for one run environment. The app makes one at launch
/// and gets each live service from it.
///
/// ```swift
/// let platform = PlatformServices(.init(environment: .live, dataRoot: PlatformStorage.defaultDataRoot()))
/// platform.start()
/// let services = platform.services(usage: root.usage, fuzzyIndex: root.fuzzyIndex)
/// // platform.icons, platform.systemContext and platform.loginItem serve the app's own packages.
/// ```
///
/// In `live` every service is real. In every other environment nothing reaches the real Mac:
///
/// | Service | Outside `live` |
/// |---|---|
/// | settings | in memory |
/// | storage | under the data root, with `<data root>/Home` as the home folder |
/// | secrets | in memory |
/// | clock | the real clock |
/// | processes, HTTP | refuse every call |
/// | file watching | real FSEvents, for folders under the data root |
/// | file dialogs | answer as if the user cancelled |
/// | permissions | all granted, never asks, opens nothing |
/// | workspace | opens, trashes and launches nothing, knows no apps |
/// | hotkeys | bookkeeping only, nothing registered with macOS |
/// | pasteboard | a private pasteboard of its own; a paste sends no keystroke |
/// | selection | never finds one |
/// | text expansion | hears no keyboard, types nothing |
/// | icons | generated images for apps, files and file types; no downloads |
/// | system context | a fixed synthetic context |
/// | login item | in memory |
///
/// A scenario or a test can still swap any of them for a fake when it builds `Services`.
///
/// Making the services touches nothing but the settings domain, which is read once. ``start()``
/// begins the work that listens to the Mac, and ``stop()`` ends it.
@MainActor public final class PlatformServices {
    /// What the app decides before making the services.
    public struct Configuration: Sendable {
        public var environment: RunEnvironment
        /// The data folder: ``PlatformStorage/defaultDataRoot(override:)`` in the app, a temporary
        /// folder elsewhere.
        public var dataRoot: URL
        /// The `UserDefaults` suite for settings in `live`. Nil uses the app's own domain. Outside
        /// `live` settings stay in memory and this is ignored.
        public var settingsSuite: String?
        /// The system context outside `live`.
        public var syntheticContext: SystemContext

        public init(
            environment: RunEnvironment,
            dataRoot: URL,
            settingsSuite: String? = nil,
            syntheticContext: SystemContext = SystemContext(
                frontmostBundleID: "com.example.editor", onBattery: false, displayCount: 1, audioRoute: .builtIn,
                isFocusOn: false)
        ) {
            self.environment = environment
            self.dataRoot = dataRoot
            self.settingsSuite = settingsSuite
            self.syntheticContext = syntheticContext
        }
    }

    public let configuration: Configuration
    public let settings: PlatformSettings
    public let storage: PlatformStorage
    public let secrets: KeychainSecrets
    public let clock: LiveClock
    public let processes: any ProcessService
    public let http: any HTTPService
    public let fileWatcher: FSEventsWatcher
    public let fileDialogs: any FileDialogService
    public let permissions: PermissionCenter
    public let workspace: LiveWorkspace
    public let hotkeys: HotkeyCenter
    /// The pasteboard. The app sets its panel closer and, while clipboard history is on, its
    /// history reader.
    public let pasteboard: LivePasteboard
    public let selection: any SelectionService
    /// Text expansion. The host sets its command runner.
    public let textExpansion: TextExpansionCenter
    /// What sends keystrokes for paste and text expansion.
    public let keystrokes: any KeystrokePoster
    /// Icons for Host and SettingsUI.
    public let icons: IconCache
    public let systemContext: SystemContextCenter
    public let loginItem: any LoginItemControl
    /// Whether one of this app's windows has key focus.
    public let ownKeyFocus: OwnKeyFocus

    private let workspaceObserver: WorkspaceObserver?
    private let keyFocusObserver: OwnKeyFocusObserver?
    private let contextMonitor: SystemContextMonitor?
    private let privatePasteboard: NSPasteboard?
    private var catalogRefresh: Task<Void, Never>?
    private var activityObservers: [any NSObjectProtocol] = []
    private var frontmostWatch: Task<Void, Never>?

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        let environment = configuration.environment
        let isLive = environment.touchesRealSystem
        let clock = LiveClock()
        let storage = PlatformStorage(dataRoot: configuration.dataRoot, environment: environment)
        let settings = PlatformSettings(
            backend: isLive
                ? UserDefaultsSettingsBackend(suiteName: configuration.settingsSuite) : MemorySettingsBackend())
        let frontmost = FrontmostTracker()
        let fileWatcher = FSEventsWatcher()
        let ownKeyFocus = OwnKeyFocus()
        self.ownKeyFocus = ownKeyFocus
        self.clock = clock
        self.storage = storage
        self.settings = settings
        self.fileWatcher = fileWatcher

        if isLive {
            let workspaceSystem = NSWorkspaceSystem()
            let permissions = PermissionCenter(
                system: MacPermissionSystem(homeDirectory: storage.homeDirectory), settings: settings, clock: clock)
            // Background reads stay out of places where a read could make macOS ask the user.
            let readGuard = ReadGuard.permissions(permissions, home: storage.homeDirectory)
            let catalog = ApplicationCatalog(
                folders: ApplicationCatalog.standardFolders(home: storage.homeDirectory),
                locate: { workspaceSystem.applicationURL(bundleID: $0) }, readGuard: readGuard)
            let http = URLSessionHTTP()
            let keystrokes = CGEventKeystrokePoster()
            secrets = KeychainSecrets(backend: SecItemKeychain())
            processes = ProcessRunner(baseEnvironment: ProcessRunner.cleanEnvironment(home: storage.homeDirectory))
            self.http = http
            fileDialogs = PanelFileDialogs()
            self.permissions = permissions
            workspace = LiveWorkspace(system: workspaceSystem, catalog: catalog, frontmost: frontmost)
            hotkeys = HotkeyCenter(system: CarbonHotkeySystem())
            self.keystrokes = keystrokes
            pasteboard = LivePasteboard(
                pasteboard: .general, permissions: permissions, poster: keystrokes, clock: clock,
                sourceApplication: { frontmost.current?.bundleID },
                anotherAppIsFrontmost: LivePasteboard.waitForAnotherApp(ownWindowIsKey: { ownKeyFocus.isKey }))
            privatePasteboard = nil
            selection = AccessibilitySelection.live(permissions: permissions, frontmost: frontmost)
            textExpansion = TextExpansionCenter(
                permissions: permissions, source: EventTapSource(), poster: keystrokes,
                secureInput: SystemSecureInput(),
                frontmostBundleID: { frontmost.current?.bundleID },
                focusChanges: { mergedSignals([frontmost.activations(), ownKeyFocus.changes()]) },
                ownAppIsKey: { ownKeyFocus.isKey })
            icons = IconCache(
                folders: storage.iconFolders, renderer: LiveIconRenderer(),
                apps: CatalogAppIcons(
                    catalog: catalog, locate: { workspaceSystem.applicationURL(bundleID: $0) }, readGuard: readGuard),
                http: http, settings: settings, watcher: fileWatcher, readGuard: readGuard)
            systemContext = SystemContextCenter()
            loginItem = MainAppLoginItem()
            workspaceObserver = WorkspaceObserver(tracker: frontmost, catalog: catalog)
            keyFocusObserver = OwnKeyFocusObserver(focus: ownKeyFocus)
            contextMonitor = SystemContextMonitor(center: systemContext, frontmost: frontmost, clock: clock)
        } else {
            let permissions = PermissionCenter(
                system: FixedPermissionSystem(.granted), settings: settings, clock: clock)
            let http = RefusingHTTP(environment: environment)
            let keystrokes = InertKeystrokePoster()
            let board = NSPasteboard.withUniqueName()
            secrets = KeychainSecrets(backend: MemoryKeychain())
            processes = RefusingProcesses(environment: environment)
            self.http = http
            fileDialogs = CancellingFileDialogs()
            self.permissions = permissions
            workspace = LiveWorkspace(
                system: IsolatedWorkspaceSystem(environment: environment), catalog: ApplicationCatalog(folders: []),
                frontmost: frontmost)
            hotkeys = HotkeyCenter(system: InertHotkeySystem())
            self.keystrokes = keystrokes
            pasteboard = LivePasteboard(pasteboard: board, permissions: permissions, poster: keystrokes, clock: clock)
            privatePasteboard = board
            selection = NoSelection()
            textExpansion = TextExpansionCenter(
                permissions: permissions, source: SilentKeyEventSource(), poster: keystrokes,
                secureInput: NoSecureInput())
            icons = IconCache(
                folders: storage.iconFolders, renderer: SyntheticIconRenderer(), apps: StaticAppIcons(), http: http,
                settings: settings, watcher: fileWatcher)
            systemContext = SystemContextCenter(configuration.syntheticContext)
            loginItem = MemoryLoginItem()
            workspaceObserver = nil
            keyFocusObserver = nil
            contextMonitor = nil
        }
    }

    public var environment: RunEnvironment { configuration.environment }

    /// Starts listening to the Mac: the frontmost app, key focus in this app's windows, whether
    /// this app is active, the app folders, power, displays, audio, session starts, the icon atlas
    /// and the favicon folder. It also checks every permission once in the background, so no later
    /// ``PermissionCenter/status(of:)`` waits, and finds out again whether a remembered Full Disk
    /// Access grant still holds. Call it once, on the main thread, after
    /// `NSApplication.shared` exists. Does nothing outside `live`.
    public func start() {
        guard environment.touchesRealSystem, catalogRefresh == nil else { return }
        workspaceObserver?.start()
        keyFocusObserver?.start()
        followAppActivity()
        contextMonitor?.start()
        catalogRefresh = workspace.catalog.refreshing(on: fileWatcher)
        icons.start()
        let permissions = permissions
        Task.detached(priority: .utility) {
            await permissions.refresh(PermissionCenter.checkedAtLaunch)
        }
        // A Full Disk Access grant remembered from an earlier launch may have been taken away
        // meanwhile. The recheck never prompts.
        permissions.userMayHaveReturned()
    }

    /// Stops listening, stops text expansion, removes every hotkey and waits for pending settings
    /// writes. Call it when the app quits.
    public func stop() {
        workspaceObserver?.stop()
        keyFocusObserver?.stop()
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activityObservers = []
        frontmostWatch?.cancel()
        frontmostWatch = nil
        contextMonitor?.stop()
        catalogRefresh?.cancel()
        catalogRefresh = nil
        textExpansion.stopNow()
        icons.stop()
        hotkeys.unregisterAll()
        privatePasteboard?.releaseGlobally()
        settings.flush()
    }

    /// Tells the permission center when this app becomes active or stops being active: permission
    /// streams check faster while the user is in the app, such as in settings or onboarding.
    private func followAppActivity() {
        let permissions = permissions
        permissions.setAppActive(NSApplication.shared.isActive)
        let changes = workspace.frontmost.changes()
        frontmostWatch = Task {
            for await _ in changes {
                permissions.userMayHaveReturned()
            }
        }
        for (name, isActive) in [
            (NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false),
        ] {
            activityObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                    permissions.setAppActive(isActive)
                })
        }
    }

    /// Plays another app copying `text` onto the private pasteboard of an isolated run, so a
    /// scenario can fill clipboard history. Does nothing in `live`, where the pasteboard is the
    /// user's.
    public func copyAsAnotherApp(_ text: String) async {
        guard privatePasteboard != nil else { return }
        await pasteboard.withPasteboard { board in
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    /// Kit's service container: Platform's services plus the two Root makes.
    public func services(
        usage: any UsageService,
        fuzzyIndex: any FuzzyIndexService,
        overrides: ServiceOverrides = ServiceOverrides()
    ) -> Services {
        Services(
            pasteboard: pasteboard, workspace: workspace, hotkeys: hotkeys, permissions: permissions,
            processes: processes, http: http, storage: storage, settings: settings, secrets: secrets, clock: clock,
            usage: usage, fuzzyIndex: fuzzyIndex, selection: selection, fileWatcher: fileWatcher,
            fileDialogs: fileDialogs, textExpansion: textExpansion, overrides: overrides)
    }
}
