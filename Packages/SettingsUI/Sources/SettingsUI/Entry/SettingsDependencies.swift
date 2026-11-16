import AppKit
import Kit
import KitHosting
import LauncherUI

/// Everything the settings window and onboarding read and write, as App builds it.
///
/// SettingsUI never imports Host, Root or Platform. App passes their implementations of the
/// KitHosting protocols here, with Kit's services and LauncherUI's theme store.
///
/// - `services`: Kit's services for the run environment. The window reads and writes general
///   settings through `services.settings` under ``HostSettings``, checks and requests permissions
///   through `services.permissions`, reveals folders and names apps through `services.workspace`,
///   and opens import, export and app pickers through `services.fileDialogs`.
/// - `features`: every registered feature, for the features pane, its settings panes and the
///   permissions list. Host implements it.
/// - `preferences`: aliases, hotkeys, favorites and switches. Host implements it.
/// - `learning`: what root search learned. Root implements it.
/// - `icons`: icon lookups that never touch the disk on the main thread. Platform implements it.
/// - `loginItem`: the open at login switch. Platform implements it.
/// - `themes`: the theme store the panel observes. The window selects, saves, imports and exports
///   themes through it and writes ``HostSettings/themeName``.
/// - `dataDirectory`: the app's data folder, revealed from the advanced pane.
/// - `launcherHotkey`: whether the launcher hotkey is bound or waits behind a macOS shortcut. App's
///   launcher hotkey implements it. Nil shows no waiting notice.
/// - `updates`: whether this build updates itself, for the General pane and onboarding. The Updates
///   package implements it for the live launcher of a release. Every other run passes, or defaults
///   to, `NoUpdates`.
public struct SettingsDependencies {
    public var services: Services
    public var features: any FeatureDirectory
    public var preferences: any ItemPreferences
    public var learning: any LearningInspector
    public var icons: any IconProvider
    public var loginItem: any LoginItemControl
    public var themes: ThemeStore
    public var dataDirectory: URL
    /// Version, license and links for the about pane. The pane opens each link through
    /// `services.workspace`.
    public var about: AboutInfo
    /// The row for an item, for the titles of favorites and learned items that are not commands.
    /// App passes `RootSource.row(for:)`. The default knows no rows and shows commands by title.
    public var lookUpItem: @MainActor (ItemID) -> Row?
    /// The host's grant flow for a permission, run when the user presses a Grant button. Nil uses
    /// ``Kit/PermissionService``: a request when the system can still ask, and the System Settings
    /// pane when it cannot.
    public var grantPermission: (@MainActor (Permission) async -> PermissionStatus)?
    /// The bundle ID of an app the user picked in an open dialog. The default reads the app's
    /// Info.plist. Tests pass a lookup over synthetic paths.
    public var bundleIdentifier: @MainActor (URL) -> String?
    /// The launcher hotkey's binding, for the notice that it waits behind a macOS shortcut.
    public var launcherHotkey: (any LauncherHotkeyStatus)?
    /// Whether this build updates itself, and the person's choices about it.
    public var updates: any UpdateControl

    public init(
        services: Services,
        features: any FeatureDirectory,
        preferences: any ItemPreferences,
        learning: any LearningInspector,
        icons: any IconProvider,
        loginItem: any LoginItemControl,
        themes: ThemeStore,
        dataDirectory: URL,
        about: AboutInfo = .fromMainBundle(),
        lookUpItem: @escaping @MainActor (ItemID) -> Row? = { _ in nil },
        grantPermission: (@MainActor (Permission) async -> PermissionStatus)? = nil,
        bundleIdentifier: @escaping @MainActor (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        launcherHotkey: (any LauncherHotkeyStatus)? = nil,
        updates: any UpdateControl = NoUpdates()
    ) {
        self.services = services
        self.features = features
        self.preferences = preferences
        self.learning = learning
        self.icons = icons
        self.loginItem = loginItem
        self.themes = themes
        self.dataDirectory = dataDirectory
        self.about = about
        self.lookUpItem = lookUpItem
        self.grantPermission = grantPermission
        self.bundleIdentifier = bundleIdentifier
        self.launcherHotkey = launcherHotkey
        self.updates = updates
    }
}

/// What the about pane shows besides ``Kit/Brand/name``.
public struct AboutInfo: Sendable, Equatable {
    /// One link in the about pane.
    public struct Link: Sendable, Equatable, Identifiable {
        public var title: String
        public var url: URL
        public var id: String { title }

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    /// The marketing version, such as "1.2".
    public var version: String
    /// The build number, or nil.
    public var build: String?
    /// The license's name, such as "MIT License".
    public var license: String
    public var links: [Link]

    public init(version: String, build: String? = nil, license: String = "MIT License", links: [Link] = []) {
        self.version = version
        self.build = build
        self.license = license
        self.links = links
    }

    /// The version and build of the running app bundle, with `links`. Outside a bundle the
    /// version reads "Development".
    public static func fromMainBundle(links: [Link] = []) -> AboutInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        return AboutInfo(version: version ?? "Development", build: version == nil ? nil : build, links: links)
    }
}
