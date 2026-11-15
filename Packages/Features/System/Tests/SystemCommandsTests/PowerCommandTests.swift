import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

@Suite("Power and session", .timeLimit(.minutes(1)))
@MainActor
struct PowerCommandTests {
    @Test(arguments: [
        ("sleep", PowerRequest.sleep), ("sleep-displays", .sleepDisplays), ("lock-screen", .lockScreen),
        ("start-screen-saver", .startScreenSaver),
    ])
    func immediateCommandsCloseThePanelFirstAndAskNothing(id: String, request: PowerRequest) async throws {
        let system = SystemHarness()
        let outcome = try await system.harness.run(id)
        #expect(system.power.requests == [request])
        #expect(outcome.kind == .close(hud: nil))
        #expect(system.harness.isClosed)
        #expect(system.harness.confirmations.isEmpty)
    }

    @Test(arguments: [
        ("log-out", PowerRequest.logOut, "Log out now?", "Logging out"),
        ("restart", .restart, "Restart your Mac now?", "Restarting"),
        ("shut-down", .shutDown, "Shut down your Mac now?", "Shutting down"),
    ])
    func sessionCommandsAlwaysAskFirst(id: String, request: PowerRequest, question: String, hud: String) async throws {
        let system = SystemHarness()
        try await system.harness.run(id)
        let confirmation = try #require(system.harness.confirmations.first)
        #expect(confirmation.title == question)
        #expect(confirmation.message == "Your apps will quit. An app with unsaved changes may ask you to save first.")
        #expect(system.power.requests == [request])
        #expect(system.harness.huds == [HUD(hud)])
    }

    @Test(arguments: ["log-out", "restart", "shut-down"])
    func decliningLeavesTheSessionAlone(id: String) async throws {
        let system = SystemHarness()
        system.harness.confirmationAnswer = false
        let outcome = try await system.harness.run(id)
        #expect(outcome.kind == .keepOpen)
        #expect(system.power.requests.isEmpty)
    }

    @Test func aHotkeyStillAsksBeforeRestarting() async throws {
        let system = SystemHarness()
        try await system.harness.run("restart", launch: .hotkey)
        #expect(system.harness.confirmations.count == 1)
        #expect(system.power.requests == [.restart])
    }

    @Test func aMissingAutomationGrantShowsThePermissionCardAndSendsNothing() async throws {
        let system = SystemHarness()
        let loginWindow = Permission.automation(bundleID: "com.apple.loginwindow")
        system.power.fail(.shutDown, with: .permissionMissing(loginWindow))
        await #expect(throws: HarnessError.permissionRequired([loginWindow])) {
            try await system.harness.run("shut-down")
        }
        #expect(system.power.requests.isEmpty)
    }

    @Test func lockScreenSaysSoWhenThisMacCannotLock() async throws {
        let system = SystemHarness()
        system.power.fail(.lockScreen, with: .unavailable)
        try await system.runShowingErrors("lock-screen")
        #expect(system.failureHUDs == ["Lock Screen is not available on this version of macOS"])
    }

    @Test func aSystemErrorIsShownWithItsCode() async throws {
        let system = SystemHarness()
        system.power.fail(.sleep, with: .failed(code: -536_870_207))
        try await system.runShowingErrors("sleep")
        #expect(system.failureHUDs == ["Your Mac could not go to sleep"])
        let failure = try #require(system.harness.actionErrors.first as? ActionFailure)
        #expect(failure.message == "macOS returned error -536870207.")
    }

    @Test(arguments: PowerRequest.allCases)
    func everyRequestHasWordsForEachFailure(request: PowerRequest) {
        let words = Strings.Power.words(for: request)
        // Titles of toasts and HUDs end without a full stop, as the other features' do.
        #expect(!words.failed.hasSuffix("."))
        #expect(!words.unavailable.hasSuffix("."))
        #expect(words.failed != words.unavailable)
    }
}
