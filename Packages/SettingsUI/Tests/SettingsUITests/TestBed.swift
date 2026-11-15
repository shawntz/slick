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
            bundleIdentifier: { url in "com.example." + url.deletingPathExtension().lastPathComponent.lowercased() })
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

/// Waits until `condition` holds, for work that a model starts in a task, such as a confirmation
/// that waits for an answer. Fails after two seconds.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
