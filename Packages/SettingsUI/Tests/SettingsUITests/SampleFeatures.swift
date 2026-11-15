import Foundation
import Kit

/// Setting keys of the sample feature, one per control kind.
nonisolated enum SampleSettings {
    static let autoPaste = SettingKey("autoPaste", default: true)
    static let layout = SettingKey("layout", default: "list")
    static let prefix = SettingKey("prefix", default: "")
    static let limit = SettingKey("limit", default: 20)
    static let pickHotkey = SettingKey("pickHotkey", default: KeyCombo?.none)
    static let ignored = SettingKey("ignored", default: [String]())
    static let skipApps = SettingKey("skipApps", default: [String]())
    static let folders = SettingKey("folders", default: [String]())
    static let groups = SettingKey("groups", default: [String]())
    static let editor = SettingKey("editor", default: "")
}

/// A made-up feature that declares every kind of settings item, a status that asks for a
/// permission, three commands and a hotkey preset.
final class SampleFeature: Feature {
    static let manifest = FeatureManifest(
        id: "sample", name: "Sample Tools", icon: .symbol("shippingbox"),
        summary: "Keeps made-up samples for tests.",
        permissions: [
            PermissionNeed(.accessibility, reason: "Paste the chosen sample into the frontmost app."),
            PermissionNeed(.inputMonitoring, reason: "Expand sample keywords as you type."),
        ])

    /// What each button run saw.
    private(set) var buttonLaunches: [LaunchSource] = []
    private(set) var optionLoads = 0
    var status: FeatureStatus? = FeatureStatus(
        .warning, "Keyword expansion is paused", message: "It needs Input Monitoring.", requires: [.inputMonitoring])

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(
                id: "open", title: "Open Sample", fallback: Fallback(title: { "Open sample \($0)" }),
                takesRootQueryOnTab: true
            ) { _ in .close() },
            Command(id: "list", title: "List Samples", subtitle: "Every sample") { _ in .close() },
            Command(id: "clear", title: "Clear Samples") { _ in .close() },
        ]
    }

    var hotkeyPresets: [HotkeyPreset] {
        [
            HotkeyPreset(
                id: "classic", name: "Classic",
                bindings: ["open": KeyCombo(.o, [.control, .option]), "list": KeyCombo(.l, [.control, .option])])
        ]
    }

    var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                "Behavior", footer: "Samples are synthetic.",
                items: [
                    .toggle("Paste after choosing", key: SampleSettings.autoPaste),
                    .picker("Layout", key: SampleSettings.layout, options: [("list", "List"), ("grid", "Grid")]),
                    .textField("Prefix", key: SampleSettings.prefix, placeholder: "None"),
                    .secret("Service token", name: "token", placeholder: "Paste a token"),
                    .stepper("Keep", key: SampleSettings.limit, range: 5...50, step: 5, unit: "samples"),
                    .hotkey("Pick hotkey", key: SampleSettings.pickHotkey),
                ]),
            SettingsSection(
                "Lists",
                items: [
                    .list("Ignored words", key: SampleSettings.ignored, placeholder: "Word"),
                    .list("Skip in apps", key: SampleSettings.skipApps, itemKind: .application),
                    .list("Folders", key: SampleSettings.folders, itemKind: .folder),
                    .multiSelect("Groups", key: SampleSettings.groups) { [weak self] in
                        self?.optionLoads += 1
                        return [SettingsChoice(id: "work", title: "Work"), SettingsChoice(id: "home", title: "Home")]
                    },
                    .application("Editor", key: SampleSettings.editor),
                ]),
            SettingsSection(
                "Maintenance",
                items: [
                    .permission(.accessibility),
                    .button("Rebuild Index") { [weak self] context in
                        self?.buttonLaunches.append(context.launch)
                        context.showToast(.success("Rebuilt"))
                    },
                    .button("Break Things") { _ in throw ActionFailure("Nothing to break", message: "Samples are fine.")
                    },
                    .button(
                        "Erase Samples", style: .destructive,
                        confirmation: Confirmation("Erase every sample?", confirmTitle: "Erase", isDestructive: true)
                    ) { [weak self] context in
                        self?.buttonLaunches.append(context.launch)
                    },
                    .note("Samples never leave the test."),
                ]),
        ])
    }
}

/// A made-up feature that is off until the user turns it on.
final class HelperFeature: Feature {
    static let manifest = FeatureManifest(
        id: "helper", name: "Window Helper", icon: .symbol("macwindow"), summary: "Names windows.",
        permissions: [
            PermissionNeed(.screenRecording, reason: "Read window titles to name windows."),
            PermissionNeed(.accessibility, reason: "Move the windows you pick."),
        ],
        isEnabledByDefault: false)

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "show", title: "Show Windows", fallback: Fallback(title: { "Windows named \($0)" })) { _ in
                .close()
            }
        ]
    }
}
