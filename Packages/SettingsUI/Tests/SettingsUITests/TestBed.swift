import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI

@testable import SettingsUI

/// Every dependency of the settings window as a fake, with two made-up features registered.
@MainActor final class TestBed {
    let fakes: FakeServices
    let directory = FakeFeatureDirectory()
    let preferences: FakeItemPreferences
    let learning: FakeLearningInspector
    let icons = FakeIconProvider()
    let loginItem = FakeLoginItem()
    let themes: ThemeStore
    let root: URL
    let sample: SampleFeature
    let helper: HelperFeature
    var lookUp: [ItemID: Row] = [:]
    var grants: [Permission] = []
    /// The launcher hotkey's binding, as App would report it.
    let hotkeyStatus = FakeLauncherHotkeyStatus()
    /// The updater. A build from source by default; a test that needs one that updates sets it.
    var updates: any UpdateControl = NoUpdates()

    init(permissions: PermissionStatus = .granted) {
        root = FileManager.default.temporaryDirectory.appending(path: "settingsui-\(UUID().uuidString)")
        fakes = FakeServices(permissions: permissions, storageRoot: root.appending(path: "storage"))
        preferences = FakeItemPreferences(directory: directory)
        learning = FakeLearningInspector(settings: fakes.settings)
        themes = ThemeStore(folder: root.appending(path: "themes"))
        sample = directory.register(SampleFeature.self, fakes: fakes)
        helper = directory.register(HelperFeature.self, fakes: fakes)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var dataDirectory: URL { root.appending(path: "data") }

    var dependencies: SettingsDependencies {
        SettingsDependencies(
            services: fakes.services, features: directory, preferences: preferences, learning: learning, icons: icons,
            loginItem: loginItem, themes: themes, dataDirectory: dataDirectory,
            about: AboutInfo(
                version: "1.2", build: "34",
                links: [AboutInfo.Link(title: "Source", url: URL(string: "https://example.com/source")!)]),
            lookUpItem: { [weak self] id in self?.lookUp[id] },
            bundleIdentifier: { url in "com.example." + url.deletingPathExtension().lastPathComponent.lowercased() },
            launcherHotkey: hotkeyStatus, updates: updates)
    }

    func context() -> SettingsContext {
        let context = SettingsContext(dependencies)
        context.toasts.lifetime = .zero
        return context
    }

    var general: FeatureSettings { HostSettings.settings(fakes.settings) }

    func sampleSettings() -> FeatureSettings { FeatureSettings(featureID: "sample", service: fakes.settings) }

    static let open = ItemID.command(feature: "sample", command: "open")
    static let list = ItemID.command(feature: "sample", command: "list")
    static let clear = ItemID.command(feature: "sample", command: "clear")
    static let show = ItemID.command(feature: "helper", command: "show")
}

/// The launcher hotkey's binding as a test sets it. ``checkNow()`` counts calls.
@MainActor final class FakeLauncherHotkeyStatus: LauncherHotkeyStatus {
    let statusChanges = ChangeSignal()
    var bound: KeyCombo? = KeyCombo(.space, .command)
    var wait: LauncherHotkeyWait?
    private(set) var checks = 0

    /// Plays the app waiting behind a macOS shortcut.
    func startWaiting(_ combo: KeyCombo = KeyCombo(.space, .command), owner: String = "Spotlight") {
        bound = nil
        wait = LauncherHotkeyWait(combo: combo, owner: owner)
        statusChanges.send()
    }

    /// Plays the app binding the combination it waited for.
    func bindWaited() {
        bound = wait?.combo
        wait = nil
        statusChanges.send()
    }

    func checkNow() {
        checks += 1
    }
}

/// Waits until `condition` holds, for work that a model starts in a task, such as a confirmation
/// that waits for an answer. Fails after two seconds.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
