import Kit

/// The general settings that more than one package reads, as typed keys.
///
/// They live under one namespace, ``namespace``, through ``FeatureSettings``, so the settings window
/// and the packages that read them share one store and one change stream:
///
/// ```swift
/// let general = HostSettings.settings(services.settings)
/// let rows = general[HostSettings.visibleRows]
/// ```
public enum HostSettings {
    /// The namespace of every key here. It contains a ".", which no feature ID may, so it can never
    /// clash with a feature's settings.
    public static let namespace = "app.general"

    /// The general settings over a settings service.
    public static func settings(_ service: any SettingsService) -> FeatureSettings {
        FeatureSettings(featureID: namespace, service: service)
    }

    // MARK: Panel

    /// How tall the glass is. Fixed keeps it as tall as the full list, so typing never resizes it.
    public static let panelSizing = SettingKey("panelSizing", default: PanelSizing.fixed)

    /// How many rows the list shows before it scrolls.
    public static let visibleRows = SettingKey("visibleRows", default: 9)

    /// How the panel appears on the hotkey.
    public static let summonStrategy = SettingKey("summonStrategy", default: SummonStrategy.layerOpacity)

    /// Which screen the panel opens on.
    public static let panelScreen = SettingKey("panelScreen", default: PanelScreen.pointer)

    /// Seconds after the panel closes before it opens on root search again instead of where the user
    /// left it. 0 returns to root at once; a negative value never does. See ``resetToRootDelay(_:)``.
    public static let resetToRootAfter = SettingKey("resetToRootAfter", default: 90)

    /// The global hotkey that opens the panel. Nil when the user cleared it.
    public static let launcherHotkey = SettingKey("launcherHotkey", default: KeyCombo?.some(KeyCombo(.space, .option)))

    // MARK: Root search

    /// True shows predicted items and situational suggestions when the query is empty.
    public static let showSuggestions = SettingKey("showSuggestions", default: true)

    /// How many rows the Suggested section holds at most.
    public static let suggestionCount = SettingKey("suggestionCount", default: 5)

    /// True shows the Favorites section when the query is empty.
    public static let showFavorites = SettingKey("showFavorites", default: true)

    /// True draws the top result's completion as ghost text after the query.
    public static let inlineCompletion = SettingKey("inlineCompletion", default: true)

    /// The commands in the fallback list under root results, in order, as `cmd:` ID strings.
    public static let fallbackCommands = SettingKey("fallbackCommands", default: [String]())

    /// The command Tab runs with the typed text, as a `cmd:` ID string. Empty when none.
    public static let tabCommand = SettingKey("tabCommand", default: "")

    /// True while learning is paused. ``LearningInspector`` reads and writes it.
    public static let learningPaused = SettingKey("learningPaused", default: false)

    // MARK: App

    /// True shows the menu bar item.
    public static let showStatusItem = SettingKey("showStatusItem", default: true)

    /// True lets the app download favicons and remote icons. False draws generic icons and makes no
    /// request for them.
    public static let fetchRemoteIcons = SettingKey("fetchRemoteIcons", default: true)

    /// The name of the selected theme: a built-in theme or a user theme file.
    public static let themeName = SettingKey("themeName", default: "Standard")

    /// True once the user finished onboarding.
    public static let onboardingDone = SettingKey("onboardingDone", default: false)

    /// Every key here, for a reset or a change stream over all of them.
    public static var allKeys: [AnySettingKey] {
        [
            panelSizing.erased, visibleRows.erased, summonStrategy.erased, panelScreen.erased,
            resetToRootAfter.erased, launcherHotkey.erased, showSuggestions.erased, suggestionCount.erased,
            showFavorites.erased, inlineCompletion.erased, fallbackCommands.erased, tabCommand.erased,
            learningPaused.erased, showStatusItem.erased, fetchRemoteIcons.erased, themeName.erased,
            onboardingDone.erased,
        ]
    }

    /// The wait that ``resetToRootAfter`` stores, as a duration: zero for at once, nil for never.
    public static func resetToRootDelay(_ seconds: Int) -> Duration? {
        seconds < 0 ? nil : .seconds(seconds)
    }

    // MARK: Values

    /// How tall the glass is.
    public enum PanelSizing: String, Hashable, Sendable, CaseIterable, SettingValue {
        /// As tall as the full list at all times, so typing never resizes the glass.
        case fixed
        /// As tall as the content. A height change caused by typing snaps in the same frame.
        case fitContent
    }

    /// How the panel appears on the hotkey.
    public enum SummonStrategy: String, Hashable, Sendable, CaseIterable, SettingValue {
        /// The panel stays ordered in and shows by flipping its root layer's opacity. Fastest.
        case layerOpacity
        /// The panel is ordered front on each summon.
        case orderFront
    }

    /// Which screen the panel opens on.
    public enum PanelScreen: String, Hashable, Sendable, CaseIterable, SettingValue {
        /// The screen under the pointer.
        case pointer
        /// The main screen, the one with the menu bar.
        case main
        /// The screen of the frontmost app's focused window.
        case activeWindow
    }
}
