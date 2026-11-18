import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

@Suite("Actions on an application", .timeLimit(.minutes(1)))
@MainActor
struct AppActionsTests {
    private let idle = [
        "Open", "Show in Finder", "Show Package Contents", "Copy Name", "Copy Bundle Identifier", "Copy Path",
        "Move to Trash",
    ]

    @Test func anAppThatIsNotRunningOffersNoRunningActions() async throws {
        let apps = try await AppsHarness()
        let actions = apps.harness.rootActions(for: try await apps.appRow("Plain"))
        #expect(actions.map(\.title) == idle)
        #expect(actions.secondary?.title == "Show in Finder", "Command-Return reveals")
        #expect(apps.unexpectedIssues.isEmpty)
    }

    @Test func aRunningAppAddsHideQuitRestartAndForceQuit() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(10, "com.example.plain", "Plain")])
        let actions = apps.harness.rootActions(for: try await apps.appRow("Plain"))
        #expect(
            actions.map(\.title) == [
                "Open", "Show in Finder", "Show Package Contents", "Hide", "Quit", "Restart", "Force Quit",
                "Copy Name", "Copy Bundle Identifier", "Copy Path", "Move to Trash",
            ])
        let forceQuit = try #require(actions.first { $0.id == "force-quit" })
        #expect(forceQuit.style == .destructive)
        #expect(forceQuit.confirmation?.confirmTitle == "Force Quit")
        #expect(apps.unexpectedIssues.isEmpty)
    }

    @Test func aSystemAppCannotBeTrashedAndAnAppWithoutAnIDHasNoIDToCopy() async throws {
        let apps = try await AppsHarness()
        #expect(
            !apps.harness.rootActions(for: try await apps.appRow("Sample Notes")).contains { $0.id == "move-to-trash" })
        #expect(
            !apps.harness.rootActions(for: try await apps.appRow("Nameless")).contains { $0.id == "copy-bundle-id" })
    }

    @Test func openLaunchesTheFirstCopyByBundleIDAndASecondCopyByPath() async throws {
        let apps = try await AppsHarness()
        let outcome = try await apps.harness.performRoot("open", on: try await apps.appRow("Sample Editor"))
        #expect(outcome.kind == .close(hud: nil))
        #expect(apps.fakes.workspace.launched == ["com.example.editor"])
        try await apps.harness.performRoot("open", on: try await apps.appRow("Sample Editor Beta"))
        #expect(apps.fakes.workspace.opened == [apps.tree.bundle("Applications/Sample Editor Beta.app")])
        try await apps.harness.performRoot("open", on: try await apps.appRow("Nameless"))
        #expect(apps.fakes.workspace.opened.last?.lastPathComponent == "Nameless.app")
    }

    /// The workspace call waits until an app that was not running finishes launching, so the panel
    /// closes before it rather than after. A launch that fails then shows as a HUD, not a toast.
    @Test func openClosesThePanelBeforeTheAppLaunches() async throws {
        let apps = try await AppsHarness()
        apps.fakes.workspace.refusesToLaunch = ["com.example.editor"]
        apps.harness.throwsActionErrors = false
        try await apps.harness.performRoot("open", on: try await apps.appRow("Sample Editor"))
        #expect(apps.harness.isClosed)
        #expect(apps.harness.toasts.isEmpty)
        #expect(apps.harness.huds.count == 1, "the panel closed first, so a HUD")
        #expect(apps.fakes.workspace.launched.isEmpty)
    }

    @Test func finderAndCopyActionsGoThroughKitServices() async throws {
        let apps = try await AppsHarness()
        let editor = try await apps.appRow("Sample Editor")
        let bundle = apps.tree.path("Applications/Sample Editor.app")
        try await apps.harness.performRoot("reveal", on: editor)
        #expect(apps.fakes.workspace.revealed.map(\.path) == [bundle])
        try await apps.harness.performRoot("show-package-contents", on: editor)
        #expect(apps.fakes.workspace.opened.map(\.path) == [bundle + "/Contents"])
        try await apps.harness.performRoot("copy-name", on: editor)
        try await apps.harness.performRoot("copy-bundle-id", on: editor)
        try await apps.harness.performRoot("copy-path", on: editor)
        #expect(apps.fakes.pasteboard.copiedTexts == ["Sample Editor", "com.example.editor", bundle])
        #expect(apps.harness.huds == ["Copied Name", "Copied Bundle Identifier", "Copied Path"])
    }

    @Test func moveToTrashConfirmsTrashesForgetsAndRescans() async throws {
        let apps = try await AppsHarness()
        let plain = try await apps.appRow("Plain")
        try await apps.harness.performRoot("move-to-trash", on: plain)
        #expect(apps.harness.confirmations.map(\.confirmTitle) == ["Move to Trash"])
        #expect(apps.fakes.workspace.trashed.map(\.lastPathComponent) == ["Plain.app"])
        #expect(apps.harness.toasts.map(\.title) == ["Moved to Trash"])
    }

    @Test func declinedMoveToTrashTouchesNothing() async throws {
        let apps = try await AppsHarness()
        apps.harness.confirmationAnswer = false
        try await apps.harness.performRoot("move-to-trash", on: try await apps.appRow("Plain"))
        #expect(apps.fakes.workspace.trashed.isEmpty)
    }

    @Test func quitHideAndForceQuitAskTheRunningAppsService() async throws {
        let apps = try await AppsHarness(running: [
            AppsHarness.runningApp(10, "com.example.plain", "Plain"),
            AppsHarness.runningApp(11, "com.example.writer", "Writer"),
            AppsHarness.runningApp(12, "com.example.sheets", "Suite Sheets"),
        ])
        let plain = try await apps.appRow("Plain")
        let writer = try await apps.appRow("Writer Pro")
        let sheets = try await apps.appRow("Suite Sheets")
        #expect(try await apps.harness.performRoot("hide", on: plain).kind == .close(hud: "Hid Plain"))
        #expect(try await apps.harness.performRoot("quit", on: writer).kind == .close(hud: "Quitting Writer Pro"))
        #expect(
            try await apps.harness.performRoot("force-quit", on: sheets).kind == .close(hud: "Force Quit Suite Sheets"))
        #expect(apps.running.requests == [.hide(pid: 10), .quit(pid: 11), .forceQuit(pid: 12)])
        #expect(apps.harness.confirmations.map(\.title) == ["Force Quit Suite Sheets?"])
    }

    @Test func declinedForceQuitQuitsNothing() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(10, "com.example.plain", "Plain")])
        apps.harness.confirmationAnswer = false
        try await apps.harness.performRoot("force-quit", on: try await apps.appRow("Plain"))
        #expect(apps.running.requests.isEmpty)
    }

    @Test func restartQuitsWaitsThenOpensAgain() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(10, "com.example.plain", "Plain")])
        let outcome = try await apps.harness.performRoot("restart", on: try await apps.appRow("Plain"))
        #expect(outcome.kind == .close(hud: "Restarted Plain"))
        #expect(apps.running.requests == [.quit(pid: 10)])
        #expect(apps.fakes.workspace.launched == ["com.example.plain"])
    }

    @Test func restartReportsAnAppThatWillNotQuit() async throws {
        let apps = try await AppsHarness(running: [AppsHarness.runningApp(10, "com.example.plain", "Plain")])
        apps.running.refuseToQuit(pid: 10)
        apps.harness.throwsActionErrors = false
        try await apps.harness.performRoot("restart", on: try await apps.appRow("Plain"))
        #expect(apps.harness.huds == [.failure("Plain Did Not Quit")], "the panel closed first, so a HUD")
        #expect(apps.fakes.workspace.launched.isEmpty)
    }

    @Test func aRowRebuiltFromASnapshotStillHasItsActions() async throws {
        let apps = try await AppsHarness()
        let row = try await apps.appRow("Sample Editor Beta")
        let snapshot = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        let actions = apps.harness.rootActions(for: snapshot)
        #expect(actions.map(\.title) == idle)
        try await apps.harness.performRoot("open", on: snapshot)
        #expect(apps.fakes.workspace.opened.map(\.lastPathComponent) == ["Sample Editor Beta.app"])
    }

    @Test func aRowWithoutPayloadFallsBackToTheScan() async throws {
        let apps = try await AppsHarness()
        _ = try await apps.appRows()
        let bare = Row(id: ItemID("app", "com.example.writer"), title: "Writer")
        #expect(apps.harness.rootActions(for: bare).map(\.title) == idle)
        #expect(apps.harness.rootActions(for: Row(id: ItemID("app", "com.example.gone"), title: "Gone")).isEmpty)
    }
}
