/// A feature: one package that adds commands, root search results, suggestions, universal actions
/// and a settings pane to Slick.
///
/// The host makes one instance per launch with ``init(context:)``, reads what it declares, and calls
/// ``activate()`` once every feature is registered. Every member except the manifest and the
/// initializer has a default, so a feature implements only what it uses.
///
/// The host reads the declarations (``commands``, ``catalogSources``, ``liveProviders``,
/// ``suggestionTriggers``, ``universalActions``, ``settingsPane``, ``hotkeyPresets``, ``status`` and
/// ``provides``) once at registration and again each time ``declarationChanges`` fires, never per
/// keystroke. Sources and providers must be the same objects on every read: keep them in stored
/// properties. `FeatureHarness` reports one made anew on each read.
@MainActor public protocol Feature: AnyObject {
    /// Who the feature is. Read before the feature is made.
    static var manifest: FeatureManifest { get }

    /// Makes the feature. Do no I/O here; start work in ``activate()``. Paths from
    /// ``FeatureContext/storage`` are fine: they touch nothing.
    init(context: FeatureContext)

    /// The commands in root search. Commands are cheap to rebuild, so closures may capture `self`.
    var commands: [Command] { get }

    /// Fires when any declaration changed, for example when a script appears on disk and adds a
    /// command, or when a setting turns a provider off. The host reads every declaration again.
    var declarationChanges: ChangeSignal? { get }

    /// Rows that join root search's synchronous catalog.
    var catalogSources: [any CatalogSource] { get }

    /// Providers that answer as the user types in root search.
    var liveProviders: [LiveProvider] { get }

    /// Proactive suggestions for root search's empty state.
    var suggestionTriggers: [any SuggestionTrigger] { get }

    /// Actions offered for text, URLs or files: the selection in the frontmost app, or what a row in
    /// any feature stands for.
    var universalActions: [UniversalActionProvider] { get }

    /// The feature's pane in the settings window.
    var settingsPane: SettingsPane? { get }

    /// Sets of hotkeys for the feature's commands that the user can apply in one step from settings,
    /// such as window layouts that match another app's shortcuts.
    var hotkeyPresets: [HotkeyPreset] { get }

    /// What a background part of the feature wants the user to know, such as "Snippet expansion
    /// needs Input Monitoring". Settings shows it at the top of the feature's pane. Send
    /// ``declarationChanges`` when it changes. Nil when all is well.
    var status: FeatureStatus? { get }

    /// Services the feature offers to the rest of Slick, such as its clipboard history for the
    /// `{clipboard offset=N}` placeholder.
    var provides: [ProvidedService] { get }

    /// Called once at launch after every feature is registered, and again if the user turns the
    /// feature back on. Features activate concurrently. Start monitors and background services here
    /// and return quickly: run anything slow in a task.
    func activate() async

    /// Called when the user turns the feature off and at quit. Stop what ``activate()`` started. The
    /// host cancels the feature's running action handlers.
    func deactivate() async

    /// The user granted a permission the manifest lists, through one of Slick's own Grant buttons:
    /// in the settings window, in onboarding, or on the panel's permission card. Called only while
    /// the feature is on, once per grant, on the main actor.
    ///
    /// Start work that waited for the grant here, such as loading contacts into root search, and
    /// send the change signals of what shows them. It replaces a permission stream held for the
    /// whole session: a feature that only waits for a grant made in Slick needs no stream. A grant
    /// the user makes straight in System Settings does not call it; read the status again when the
    /// user next runs one of your commands, or hold a stream while that matters. Default nothing.
    func permissionGranted(_ permission: Permission) async
}

extension Feature {
    public var commands: [Command] { [] }
    public var declarationChanges: ChangeSignal? { nil }
    public var catalogSources: [any CatalogSource] { [] }
    public var liveProviders: [LiveProvider] { [] }
    public var suggestionTriggers: [any SuggestionTrigger] { [] }
    public var universalActions: [UniversalActionProvider] { [] }
    public var settingsPane: SettingsPane? { nil }
    public var hotkeyPresets: [HotkeyPreset] { [] }
    public var status: FeatureStatus? { nil }
    public var provides: [ProvidedService] { [] }
    public func activate() async {}
    public func deactivate() async {}
    public func permissionGranted(_ permission: Permission) async {}
}

/// Who a feature is: its ID, name, icon and the permissions it may ask for.
public struct FeatureManifest: Sendable {
    /// Unique among features: a lowercase letter, then lowercase letters, digits and "-". It prefixes
    /// the feature's command IDs, settings keys and secrets, so changing it resets them.
    public var id: String
    /// The name in settings, such as "Clipboard History".
    public var name: String
    public var icon: Icon
    /// One sentence for settings and onboarding.
    public var summary: String
    /// Every permission the feature's commands, actions, forms or triggers may need, each with the
    /// reason the host shows when asking.
    public var permissions: [PermissionNeed]
    /// False keeps the feature off until the user turns it on, for features that watch the user.
    public var isEnabledByDefault: Bool
    /// True starts the feature's switch on in onboarding's Optional Features step, so a new user
    /// gets it unless they turn it off there. Only for a feature that is off by default; the
    /// validator reports it on one that is on. A user who skips onboarding gets the feature off.
    /// Default false.
    public var isSuggestedInOnboarding: Bool

    public init(
        id: String,
        name: String,
        icon: Icon,
        summary: String = "",
        permissions: [PermissionNeed] = [],
        isEnabledByDefault: Bool = true,
        isSuggestedInOnboarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.summary = summary
        self.permissions = permissions
        self.isEnabledByDefault = isEnabledByDefault
        self.isSuggestedInOnboarding = isSuggestedInOnboarding
    }
}
