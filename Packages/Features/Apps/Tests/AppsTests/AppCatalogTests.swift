import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

@Suite("Applications in root search", .timeLimit(.minutes(1)))
@MainActor
struct AppCatalogTests {
    @Test func declaresNothingInvalidBesidesTheReservedNamespace() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.harness.catalogRows()
        #expect(apps.unexpectedIssues.isEmpty)
        #expect(apps.harness.pendingIssues.isEmpty)
        #expect(apps.feature.catalogSources.map(\.namespace) == ["app", "setting"])
    }

    @Test func eachAppIsARowWithItsIconSubtitlePayloadAndFile() async throws {
        let apps = try await AppsHarness()
        let editor = try await apps.appRow("Sample Editor")
        #expect(editor.id == ItemID("app", "com.example.editor"))
        #expect(editor.icon == .app(bundleID: "com.example.editor"))
        #expect(editor.subtitle == "Application")
        #expect(editor.keywords.contains("Editor"))
        #expect(editor.accessories.isEmpty)
        #expect(editor.memory == .learnOnly)
        #expect(editor.represents == .files([apps.tree.bundle("Applications/Sample Editor.app")]))
        #expect(editor.represents?.text == apps.tree.path("Applications/Sample Editor.app"))
        let nameless = try await apps.appRow("Nameless")
        #expect(nameless.icon == .file(path: apps.tree.path("Applications/Nameless.app")))
    }

    @Test func aRunningAppShowsTheRunningTag() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(10, "com.example.plain", "Plain")])
        #expect(try await apps.appRow("Plain").accessories == [.tag("Running")])
        #expect(try await apps.appRow("Writer Pro").accessories.isEmpty)
    }

    @Test func aLaunchOrQuitSendsTheCatalogSignal() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.appRows()
        await apps.waitForChange { apps.running.launch(AppsHarness.runningApp(11, "com.example.writer", "Writer")) }
        #expect(try await apps.appRow("Writer Pro").accessories == [.tag("Running")])
        await apps.waitForChange { apps.running.terminate(pid: 11) }
        #expect(try await apps.appRow("Writer Pro").accessories.isEmpty)
    }

    @Test func watchesTheUserFoldersButNotTheSystemOnes() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.appRows()
        let watched = Set(apps.fakes.fileWatcher.watchedDirectories.map(\.path))
        #expect(watched.contains(apps.tree.applications.path))
        #expect(watched.contains(apps.tree.home.path))
        #expect(!watched.contains(apps.tree.system.path))
    }

    @Test func rescansEverythingWhenAFolderChanges() async throws {
        let apps = try await AppsHarness()
        #expect(try await !apps.appRows().contains { $0.title == "New Tool" })
        let signal = apps.feature.changes.generation
        try apps.tree.install("Applications/New Tool.app", bundleID: "com.example.new-tool")
        apps.fakes.fileWatcher.simulateChange([apps.tree.applications.appending(path: "New Tool.app")])
        try await apps.harness.settle()
        #expect(try await apps.appRows().contains { $0.title == "New Tool" })
        #expect(apps.feature.changes.generation == signal + 1)
        try apps.tree.remove("Applications/Plain.app")
        apps.fakes.fileWatcher.simulateChange([apps.tree.applications.appending(path: "Plain.app")])
        try await apps.harness.settle()
        #expect(try await !apps.appRows().contains { $0.title == "Plain" })
    }

    @Test func aChangeThatAltersNothingSendsNoSignal() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.appRows()
        let signal = apps.feature.changes.generation
        apps.fakes.fileWatcher.simulateChange([apps.tree.applications.appending(path: "Plain.app/Contents")])
        try await apps.harness.settle()
        #expect(apps.feature.changes.generation == signal)
    }

    @Test func extraFoldersFromSettingsAreScannedAndWatched() async throws {
        let apps = try await AppsHarness()
        #expect(try await !apps.appRows().contains { $0.title == "Extra Tool" })
        apps.harness.context.settings[AppsSettings.extraFolders] = [apps.tree.extra.path]
        try await apps.harness.settle()
        #expect(try await apps.appRows().contains { $0.title == "Extra Tool" })
        #expect(apps.fakes.fileWatcher.watchedDirectories.contains { $0.path == apps.tree.extra.path })
    }

    @Test func hiddenAppsLeaveRootSearch() async throws {
        let apps = try await AppsHarness()
        #expect(try await apps.appRows().contains { $0.title == "Writer Pro" })
        apps.harness.context.settings[AppsSettings.hiddenApps] = ["com.example.writer"]
        #expect(try await !apps.appRows().contains { $0.title == "Writer Pro" })
        let source = try #require(apps.feature.catalogSources.first { $0.namespace == "app" })
        #expect(source.reloadsOnSettings == [AppsSettings.hiddenApps.erased])
    }

    @Test func theRescanButtonReportsTheCount() async throws {
        let apps = try await AppsHarness()
        try await apps.harness.pressSettingsButton("Rescan Applications")
        #expect(apps.harness.toasts.map(\.title) == ["Found 15 Applications"])
    }

    @Test func theSettingsPaneDeclaresItsKeys() {
        let harness = FeatureHarness(AppsFeature.self)
        let keys = (harness.feature.settingsPane?.sections.flatMap(\.items) ?? []).compactMap(\.control.key)
        #expect(
            keys == [
                AppsSettings.extraFolders.erased, AppsSettings.hiddenApps.erased,
                AppsSettings.showsSettingsPanes.erased, AppsSettings.keepRunning.erased,
            ])
    }

    @Test func withoutAnOverrideASelfTestReadsTheSyntheticTree() async throws {
        let harness = FeatureHarness(AppsFeature.self)
        await harness.activate()
        let rows = try await harness.catalogRows()
        #expect(
            rows.filter { $0.id.namespace == "app" }.map(\.title) == [
                "Text Editor", "Disk Tool", "Web Browser", "Calendar", "Mail", "Notes",
            ])
        #expect(rows.filter { $0.accessories == [.tag("Running")] }.map(\.title) == ["Mail", "Notes"])
        #expect(rows.contains { $0.title == "DNS servers" })
        let root = harness.fakes.storage.root.path
        #expect(rows.compactMap(\.represents?.text).allSatisfy { $0.hasPrefix(root) || $0.hasPrefix("x-apple") })
    }

    @Test func deactivatingStopsTheWatch() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.appRows()
        #expect(!apps.fakes.fileWatcher.watchedDirectories.isEmpty)
        await apps.harness.deactivate()
        // The fake forgets a watch as soon as the task reading it is cancelled.
        #expect(apps.fakes.fileWatcher.watchedDirectories.isEmpty)
    }
}
