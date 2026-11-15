import os

/// What a feature receives when it is made: its identity, the run environment, and every service it
/// may use. All side effects go through these services, so the same feature runs against the real
/// Mac in the app and against fakes in tests and scenarios.
///
/// The context is a plain `Sendable` value. Copy services out of it into background tasks freely.
public struct FeatureContext: Sendable {
    /// The feature's manifest ID.
    public let featureID: String
    public let environment: RunEnvironment
    /// The feature's typed settings, namespaced by its ID.
    public let settings: FeatureSettings
    /// The feature's secrets, namespaced by its ID, kept in the Keychain.
    public let secrets: FeatureSecrets
    /// The feature's own folders.
    public let storage: FeatureStorage
    /// A logger whose category is the feature ID. Mark anything that comes from the user's data
    /// `privacy: .private`. Interpolating needs `import os` in the file that logs.
    public let log: Logger

    private let services: Services

    /// Made by the host and by `FeatureHarness`.
    public init(featureID: String, environment: RunEnvironment, services: Services) {
        self.featureID = featureID
        self.environment = environment
        self.services = services
        self.settings = FeatureSettings(featureID: featureID, service: services.settings)
        self.secrets = FeatureSecrets(featureID: featureID, service: services.secrets)
        self.storage = FeatureStorage(featureID: featureID, service: services.storage)
        self.log = KitLog.logger(category: featureID)
    }

    public var pasteboard: any PasteboardService { services.pasteboard }
    public var workspace: any WorkspaceService { services.workspace }
    public var hotkeys: any HotkeyService { services.hotkeys }
    /// Reads permission status and its changes. Asking for a permission happens only from an
    /// action; see ``ActionContext/requestPermission(_:)``.
    public var permissions: PermissionReader { PermissionReader(services.permissions) }
    public var processes: any ProcessService { services.processes }
    public var http: any HTTPService { services.http }
    public var clock: any ClockService { services.clock }
    public var usage: any UsageService { services.usage }
    public var fuzzyIndex: any FuzzyIndexService { services.fuzzyIndex }
    public var selection: any SelectionService { services.selection }
    public var fileWatcher: any FileWatchService { services.fileWatcher }
    public var fileDialogs: any FileDialogService { services.fileDialogs }
    public var textExpansion: any TextExpansionService { services.textExpansion }

    var overrides: ServiceOverrides { services.overrides }
}
