import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

/// A synthetic tree of application bundles and Settings panes in a fresh temporary folder, removed
/// when the tree is released. It holds every case the scan must handle; no test reads a real app.
nonisolated final class AppTree: Sendable {
    let root: URL

    var applications: URL { root.appending(path: "Applications") }
    var system: URL { root.appending(path: "System/Applications") }
    var coreServices: URL { root.appending(path: "CoreServices") }
    var home: URL { root.appending(path: "home/Applications") }
    var extra: URL { root.appending(path: "Extra") }
    var extensions: URL { root.appending(path: "Extensions") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "apps-tests-\(UUID().uuidString)")
        try writeApps()
        try writePanes()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// The roots in the order the live library uses: user folders first, then the system's.
    var roots: [AppScanRoot] {
        [
            AppScanRoot(applications, depth: 4),
            AppScanRoot(applications.appending(path: "Utilities"), depth: 1),
            AppScanRoot(system, depth: 2, isSystem: true),
            AppScanRoot(home, depth: 4),
            AppScanRoot(coreServices, depth: 1, only: ["Finder Like.app"], isSystem: true),
        ]
    }

    /// A library over the tree. It holds the tree, so the folder lives as long as the library does.
    func library(languages: [String] = ["en"]) -> FolderAppLibrary {
        FolderAppLibrary(
            standardRoots: roots, extensionsFolder: extensions, reader: BundleReader(languages: languages),
            prepare: { withExtendedLifetime(self) {} })
    }

    /// A bundle's URL as the feature makes it: a folder.
    func bundle(_ relative: String) -> URL {
        URL(filePath: path(relative), directoryHint: .isDirectory)
    }

    func path(_ relative: String) -> String {
        root.appending(path: relative).path
    }

    /// Adds an app after the first scan, as an installer would.
    func install(_ relative: String, bundleID: String, name: String? = nil) throws {
        var info: [String: Any] = [:]
        if let name { info["CFBundleName"] = name }
        try SyntheticApps.writeApp(at: root.appending(path: relative), bundleID: bundleID, info: info)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: relative))
    }

    private func writeApps() throws {
        let english = ["CFBundleDisplayName": "Sample Editor"]
        let german = ["CFBundleDisplayName": "Beispiel-Editor"]
        // A localized display name beats the bundle's own names.
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Sample Editor.app"), bundleID: "com.example.editor",
            info: ["CFBundleName": "Editor", "CFBundleDevelopmentRegion": "en"],
            localized: ["en": english, "de": german], asLoctable: true)
        // A second copy of the same app, such as a beta.
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Sample Editor Beta.app"), bundleID: "com.example.editor",
            info: ["CFBundleName": "Editor"], localized: ["en": english], asLoctable: true)
        // An app inside an app is a helper, never listed.
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Sample Editor.app/Contents/Helpers/Editor Helper.app"),
            bundleID: "com.example.editor.helper")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Writer Pro.app"), bundleID: "com.example.writer",
            info: ["CFBundleDisplayName": "Writer", "CFBundleName": "WriterPro"])
        try SyntheticApps.writeApp(at: applications.appending(path: "Plain.app"), bundleID: "com.example.plain")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Nameless.app"), bundleID: nil, info: ["CFBundleName": "Nameless"])
        try SyntheticApps.writeApp(
            at: applications.appending(path: ".Hidden Helper.app"), bundleID: "com.example.hidden-helper")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Vendor Suite/Suite Sheets.app"), bundleID: "com.example.sheets")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Utilities/Sample Monitor.app"), bundleID: "com.example.monitor")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Deep/A/B/Found Deep.app"), bundleID: "com.example.found-deep")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Deep/A/B/C/Too Deep.app"), bundleID: "com.example.too-deep")
        try SyntheticApps.writeApp(
            at: applications.appending(path: "Settings Like.app"), bundleID: "com.apple.systempreferences",
            info: ["CFBundleName": "Settings Like", "CFBundleAlternateNames": ["Preferences"]])
        try writeWrappedApp()
        try writeLinks()
        // A system app localized the way third-party apps are: one strings file per language.
        try SyntheticApps.writeApp(
            at: system.appending(path: "Sample Notes.app"), bundleID: "com.example.notes",
            info: ["CFBundleName": "Notes", "CFBundleDevelopmentRegion": "en"],
            localized: ["en": ["CFBundleDisplayName": "Sample Notes"], "de": ["CFBundleDisplayName": "Notizen"]])
        try SyntheticApps.writeApp(at: coreServices.appending(path: "Finder Like.app"), bundleID: "com.example.finder")
        try SyntheticApps.writeApp(at: coreServices.appending(path: "Agent.app"), bundleID: "com.example.agent")
        try SyntheticApps.writeApp(at: home.appending(path: "Web App.app"), bundleID: "com.example.webapp")
        try SyntheticApps.writeApp(at: extra.appending(path: "Tools/Extra Tool.app"), bundleID: "com.example.tool")
    }

    /// An iOS app installed on a Mac keeps its Info.plist in `WrappedBundle`, a link into `Wrapper`.
    private func writeWrappedApp() throws {
        let bundle = applications.appending(path: "Pocket Game.app")
        try SyntheticApps.writePlist(
            ["CFBundleIdentifier": "com.example.pocket-game", "CFBundleDisplayName": "Pocket Game"],
            to: bundle.appending(path: "Wrapper/Pocket Game.app/Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appending(path: "WrappedBundle").path, withDestinationPath: "Wrapper/Pocket Game.app")
    }

    /// Two links to one app outside the roots, as `/Applications/Safari.app` links into the cryptex,
    /// and a link to a folder of apps.
    private func writeLinks() throws {
        let elsewhere = root.appending(path: "Elsewhere")
        try SyntheticApps.writeApp(at: elsewhere.appending(path: "Linked Browser.app"), bundleID: "com.example.browser")
        try SyntheticApps.writeApp(
            at: elsewhere.appending(path: "Folder/Folder App.app"), bundleID: "com.example.folder-app")
        let manager = FileManager.default
        try manager.createSymbolicLink(
            atPath: applications.appending(path: "Linked Browser.app").path,
            withDestinationPath: elsewhere.appending(path: "Linked Browser.app").path)
        try manager.createSymbolicLink(
            atPath: applications.appending(path: "Zz Second Link.app").path,
            withDestinationPath: elsewhere.appending(path: "Linked Browser.app").path)
        try manager.createSymbolicLink(
            atPath: applications.appending(path: "Linked Folder").path,
            withDestinationPath: elsewhere.appending(path: "Folder").path)
    }

    private func writePanes() throws {
        try SyntheticApps.writePane(
            at: extensions.appending(path: "Network.appex"), id: "com.example.network-settings", name: "Network",
            anchors: [
                .init(id: "DNS", titles: ["DNS servers", "Name servers"], index: "dns, domain, resolver"),
                .init(id: "Advanced Ethernet", titles: ["Ethernet options"], index: "mtu, speed, duplex"),
                .init(id: "Main", titles: ["Network"], index: "internet"),
            ])
        try SyntheticApps.writePane(
            at: extensions.appending(path: "Sound.appex"), id: "com.example.sound-settings", name: "Sound",
            anchors: [.init(id: "output", titles: ["Output device"], index: "speakers")],
            localized: ["en": ["CFBundleDisplayName": "Sound"], "de": ["CFBundleDisplayName": "Ton"]])
        let battery = extensions.appending(path: "PowerPreferences.appex")
        try SyntheticApps.writePane(
            at: battery, id: "com.apple.Battery-Settings.extension", name: "PowerPreferences", anchors: [])
        try SyntheticApps.writeLocalized(
            ["en": ["BATTERY_PREF_TITLE": "Battery"], "de": ["BATTERY_PREF_TITLE": "Batterie"]], table: "Localizable",
            asLoctable: true, in: battery)
        try SyntheticApps.writePane(
            at: extensions.appending(path: "Widget.appex"), id: "com.example.widget", name: "Widget", anchors: [],
            extensionPoint: "com.apple.widgetkit-extension")
        try SyntheticApps.writePane(
            at: extensions.appending(path: "Locked.appex"), id: "com.example.locked-settings", name: "Locked",
            anchors: [], allowsLinks: false)
    }
}

/// The one issue Kit reports for this feature today: Kit reserves the `app` namespace for root
/// search, while this feature is the one meant to own it. See the feature's report.
nonisolated let reservedAppNamespaceIssue: FeatureIssue = "namespace \"app\" is reserved for root search"

/// A harness over the synthetic tree and simulated running apps.
@MainActor
struct AppsHarness {
    let tree: AppTree
    let running: SimulatedRunningApps
    let harness: FeatureHarness<AppsFeature>

    init(running apps: [RunningApp] = [], languages: [String] = ["en"]) async throws {
        tree = try AppTree()
        running = SimulatedRunningApps(apps)
        let fakes = FakeServices()
        fakes.override(AppLibraryKey.self, with: tree.library(languages: languages))
        fakes.override(RunningAppsKey.self, with: running)
        harness = FeatureHarness(AppsFeature.self, fakes: fakes)
        await harness.activate()
    }

    var feature: AppsFeature { harness.feature }
    var fakes: FakeServices { harness.fakes }

    /// The issues the harness found, without the reserved namespace one.
    var unexpectedIssues: [FeatureIssue] {
        harness.issues.filter { $0 != reservedAppNamespaceIssue }
    }

    /// The catalog rows in the app namespace.
    func appRows() async throws -> [Row] {
        try await harness.catalogRows().filter { $0.id.namespace == AppCatalog.namespace }
    }

    /// The catalog rows in the setting namespace.
    func settingRows() async throws -> [Row] {
        try await harness.catalogRows().filter { $0.id.namespace == SettingsPaneCatalog.namespace }
    }

    func appRow(_ title: String) async throws -> Row {
        try #require(try await appRows().first { $0.title == title })
    }

    /// Runs `body`, then waits until the feature sends its change signal, as it does after the
    /// running apps change.
    func waitForChange(_ body: () -> Void) async {
        let signal = feature.changes.stream()
        body()
        for await _ in signal { break }
    }

    static func runningApp(_ pid: Int32, _ bundleID: String, _ name: String, path: String? = nil) -> RunningApp {
        RunningApp(pid: pid, bundleID: bundleID, name: name, path: path ?? "/Example/\(name).app", isHidden: false)
    }
}
