import Kit
import KitHosting
import Observation

/// The general pane: the launcher hotkey, open at login, the menu bar item, where and how big the
/// panel opens, and when it returns to root search. While a macOS shortcut holds the launcher
/// hotkey, the pane says so under the recorder, with a button that opens Keyboard settings.
@Observable final class GeneralModel {
    /// A choice for how long the panel keeps the page the user left.
    struct ResetChoice: Hashable, Identifiable {
        var seconds: Int
        var title: String
        var id: Int { seconds }
    }

    static let resetChoices: [ResetChoice] = [
        ResetChoice(seconds: 0, title: "Immediately"),
        ResetChoice(seconds: 15, title: "After 15 seconds"),
        ResetChoice(seconds: 30, title: "After 30 seconds"),
        ResetChoice(seconds: 90, title: "After 90 seconds"),
        ResetChoice(seconds: 180, title: "After 3 minutes"),
        ResetChoice(seconds: 600, title: "After 10 minutes"),
        ResetChoice(seconds: -1, title: "Never"),
    ]

    static let visibleRowRange = 3...15

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()
    /// The launcher hotkey's recorder.
    let launcherHotkey: HotkeyRecorderModel

    init(context: SettingsContext) {
        self.context = context
        launcherHotkey = context.recorder(
            HotkeyTargets.launcher(general: context.general, preferences: context.preferences))
        tasks.follow(HostSettings.allKeys, in: context.general, bumping: revision)
        let recorder = launcherHotkey
        tasks.add(
            Task { [stream = context.general.changes(of: HostSettings.launcherHotkey)] in
                for await _ in stream { recorder.refresh() }
            })
        if let status = context.launcherHotkey {
            tasks.follow(status.statusChanges, bumping: revision)
        }
    }

    // MARK: Launcher hotkey

    /// The stored launcher hotkey while a macOS shortcut holds it and nothing is bound, or nil.
    var hotkeyWait: LauncherHotkeyWait? {
        revision.track()
        return context.launcherHotkey?.wait
    }

    /// The sentence under the recorder while the hotkey waits.
    var hotkeyWaitNote: String? {
        hotkeyWait.map(SpotlightShortcutGuide.waitingNote)
    }

    /// Opens the Keyboard pane of System Settings, where the shortcut that holds the hotkey lives.
    func openKeyboardSettings() {
        context.openKeyboardSettings()
    }

    private var general: FeatureSettings { context.general }

    private func read<Value>(_ key: SettingKey<Value>) -> Value {
        revision.track()
        return general[key]
    }

    private func write<Value>(_ key: SettingKey<Value>, _ value: Value) {
        general[key] = value
        revision.bump()
    }

    // MARK: App

    /// True when the app opens at login. Reads the system's answer, which can differ from what the
    /// user last asked for.
    var launchAtLogin: Bool {
        get {
            revision.track()
            return context.dependencies.loginItem.isEnabled
        }
        set {
            do {
                try context.dependencies.loginItem.setEnabled(newValue)
            } catch {
                context.toasts.show(
                    error, title: newValue ? "Could not open at login" : "Could not stop opening at login")
            }
            revision.bump()
        }
    }

    var showStatusItem: Bool {
        get { read(HostSettings.showStatusItem) }
        set { write(HostSettings.showStatusItem, newValue) }
    }

    /// True when the launcher has no hotkey and no menu bar item, so nothing opens it.
    var isUnreachable: Bool {
        !showStatusItem && launcherHotkey.combo == nil
    }

    // MARK: Panel

    var panelScreen: HostSettings.PanelScreen {
        get { read(HostSettings.panelScreen) }
        set { write(HostSettings.panelScreen, newValue) }
    }

    var panelSizing: HostSettings.PanelSizing {
        get { read(HostSettings.panelSizing) }
        set { write(HostSettings.panelSizing, newValue) }
    }

    /// Rows the list shows before it scrolls, kept inside ``visibleRowRange``.
    var visibleRows: Int {
        get { read(HostSettings.visibleRows) }
        set {
            write(
                HostSettings.visibleRows,
                min(max(newValue, Self.visibleRowRange.lowerBound), Self.visibleRowRange.upperBound))
        }
    }

    /// Seconds before the panel opens on root search again; see ``HostSettings/resetToRootAfter``.
    var resetToRootAfter: Int {
        get { read(HostSettings.resetToRootAfter) }
        set { write(HostSettings.resetToRootAfter, newValue < 0 ? -1 : newValue) }
    }

    /// The reset choices, with the stored value added when it is not one of them.
    var resetChoices: [ResetChoice] {
        let stored = resetToRootAfter
        guard !Self.resetChoices.contains(where: { $0.seconds == stored }) else { return Self.resetChoices }
        return Self.resetChoices + [ResetChoice(seconds: stored, title: "After \(stored) seconds")]
    }

    static func title(_ screen: HostSettings.PanelScreen) -> String {
        switch screen {
        case .pointer: "Screen with the pointer"
        case .main: "Main screen"
        case .activeWindow: "Screen with the active window"
        }
    }

    static func title(_ sizing: HostSettings.PanelSizing) -> String {
        switch sizing {
        case .fixed: "Always full height"
        case .fitContent: "Fit the results"
        }
    }
}
