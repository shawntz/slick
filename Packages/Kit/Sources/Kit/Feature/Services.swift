/// Every service, as the host builds them for one run environment.
public struct Services: Sendable {
    public var pasteboard: any PasteboardService
    public var workspace: any WorkspaceService
    public var hotkeys: any HotkeyService
    public var permissions: any PermissionService
    public var processes: any ProcessService
    public var http: any HTTPService
    public var storage: any StorageService
    public var settings: any SettingsService
    public var secrets: any SecretService
    public var clock: any ClockService
    public var usage: any UsageService
    public var fuzzyIndex: any FuzzyIndexService
    public var selection: any SelectionService
    public var fileWatcher: any FileWatchService
    public var fileDialogs: any FileDialogService
    public var textExpansion: any TextExpansionService
    /// Implementations of features' own services that replace the usual choice. Tests set them; the
    /// host leaves it empty.
    public var overrides: ServiceOverrides

    public init(
        pasteboard: any PasteboardService,
        workspace: any WorkspaceService,
        hotkeys: any HotkeyService,
        permissions: any PermissionService,
        processes: any ProcessService,
        http: any HTTPService,
        storage: any StorageService,
        settings: any SettingsService,
        secrets: any SecretService,
        clock: any ClockService,
        usage: any UsageService,
        fuzzyIndex: any FuzzyIndexService,
        selection: any SelectionService,
        fileWatcher: any FileWatchService,
        fileDialogs: any FileDialogService,
        textExpansion: any TextExpansionService,
        overrides: ServiceOverrides = ServiceOverrides()
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.hotkeys = hotkeys
        self.permissions = permissions
        self.processes = processes
        self.http = http
        self.storage = storage
        self.settings = settings
        self.secrets = secrets
        self.clock = clock
        self.usage = usage
        self.fuzzyIndex = fuzzyIndex
        self.selection = selection
        self.fileWatcher = fileWatcher
        self.fileDialogs = fileDialogs
        self.textExpansion = textExpansion
        self.overrides = overrides
    }
}
