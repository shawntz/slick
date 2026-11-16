import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

@Suite("Running Applications and Quit All", .timeLimit(.minutes(1)))
@MainActor
struct RunningAppsTests {
    private static let three = [
        AppsHarness.runningApp(10, "com.example.writer", "Writer"),
        AppsHarness.runningApp(11, "com.apple.finder", "Finder"),
        AppsHarness.runningApp(
            12, "com.example.disk-image-app", "Mounted Tool", path: "/Volumes/Example/Mounted Tool.app"),
    ]

    @Test func listsTheRunningAppsByNameWithTheCatalogsIDs() async throws {
        let apps = try await AppsHarness(running: Self.three)
        try await apps.harness.run("running")
        #expect(apps.harness.sections.map(\.title) == ["Running Applications"])
        #expect(apps.harness.sections.first?.showsCount == true)
        #expect(apps.harness.rows.map(\.title) == ["Finder", "Mounted Tool", "Writer Pro"], "the installed app's name")
        #expect(apps.harness.rows.last?.id == ItemID("app", "com.example.writer"), "the installed app's ID")
        #expect(apps.harness.rows.last?.keywords == ["Writer", "WriterPro"], "and its keywords")
        let mounted = try #require(apps.harness.rows.dropFirst().first)
        #expect(mounted.id == ItemID("app", "com.example.disk-image-app"))
        #expect(apps.unexpectedIssues.isEmpty)
    }

    @Test func offersTheSameActionsAsRootSearch() async throws {
        let apps = try await AppsHarness(running: Self.three)
        try await apps.harness.run("running")
        try apps.harness.select(title: "Writer Pro")
        #expect(apps.harness.actions().map(\.title).contains("Quit"))
        #expect(
            apps.harness.actions().map(\.id)
                == apps.harness.rootActions(for: try await apps.appRow("Writer Pro")).map(\.id))
        try apps.harness.select(title: "Mounted Tool")
        #expect(apps.harness.actions().map(\.title).contains("Move to Trash"), "outside the scan, yet not a system app")
    }

    @Test func quittingFromThePageKeepsItOpenAndDropsTheRow() async throws {
        let apps = try await AppsHarness(running: Self.three)
        try await apps.harness.run("running")
        try apps.harness.select(title: "Writer Pro")
        let outcome = try await apps.harness.perform("quit")
        #expect(outcome.kind == .keepOpen)
        #expect(apps.harness.toasts.map(\.title) == ["Quitting Writer Pro"])
        try await apps.harness.reloadPage()
        #expect(apps.harness.rows.map(\.title) == ["Finder", "Mounted Tool"])
    }

    @Test func thePageFollowsLaunchesAndHides() async throws {
        let apps = try await AppsHarness(running: Self.three)
        try await apps.harness.run("running")
        apps.running.launch(AppsHarness.runningApp(13, "com.example.plain", "Plain"))
        try await apps.harness.waitForChange()
        #expect(apps.harness.rows.map(\.title) == ["Finder", "Mounted Tool", "Plain", "Writer Pro"])
        try apps.harness.select(title: "Plain")
        try await apps.harness.perform("hide")
        try await apps.harness.reloadPage()
        #expect(apps.harness.rows.first { $0.title == "Plain" }?.accessories == [.tag("Hidden")])
    }

    @Test func showsAnEmptyStateWhenNothingRuns() async throws {
        let apps = try await AppsHarness()
        try await apps.harness.run("running")
        #expect(apps.harness.rows.isEmpty)
        #expect(apps.harness.page?.emptyState?.title == "No Running Applications")
    }

    @Test func quitAllAsksFirstAndKeepsFinderRunning() async throws {
        let apps = try await AppsHarness(running: Self.three)
        let outcome = try await apps.harness.run("quit-all")
        #expect(apps.harness.confirmations.map(\.title) == ["Quit All Applications?"])
        #expect(apps.harness.confirmations.first?.suppressionKey == "quit-all")
        #expect(outcome.kind == .close(hud: "Quitting 2 Applications"))
        #expect(apps.running.requests == [.quit(pid: 12), .quit(pid: 10)])
    }

    @Test func quitAllHonorsTheKeepRunningSettingAndNeverQuitsThisApp() async throws {
        let apps = try await AppsHarness(
            running: Self.three + [AppsHarness.runningApp(14, Brand.bundleID, Brand.name)])
        apps.harness.context.settings[AppsSettings.keepRunning] = ["com.example.writer"]
        try await apps.harness.run("quit-all")
        #expect(apps.running.requests == [.quit(pid: 11), .quit(pid: 12)])
    }

    @Test func declinedQuitAllQuitsNothing() async throws {
        let apps = try await AppsHarness(running: Self.three)
        apps.harness.confirmationAnswer = false
        try await apps.harness.run("quit-all")
        #expect(apps.running.requests.isEmpty)
    }

    @Test func quitAllWithNothingToQuitSaysSo() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(11, "com.apple.finder", "Finder")])
        #expect(try await apps.harness.run("quit-all").kind == .close(hud: "No Applications to Quit"))
    }

    @Test func aHotkeyLaunchOfQuitAllStillAsks() async throws {
        let apps = try await AppsHarness(running: Self.three)
        try await apps.harness.run("quit-all", launch: .hotkey)
        #expect(apps.harness.confirmations.count == 1)
        #expect(apps.harness.huds == ["Quitting 2 Applications"])
    }
}
