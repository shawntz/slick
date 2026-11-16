import AppKit
import Foundation
import Host
import Kit
import KitTesting
import LauncherUI
import Platform
import Testing

@testable import SlickApp

/// What a web page can make the launcher do with links, through the joined app on a panel placed
/// far off every screen and never key. The page that asks waits on a fake clock, so no test here
/// depends on how fast this Mac runs.
@Suite("Link safety", .serialized, .timeLimit(.minutes(3)))
@MainActor struct LinkSafetyTests {
    /// The joined launcher in the scenario environment, with a workspace that records.
    @MainActor final class Launcher {
        let folder: URL
        let assembly: Assembly
        let panel: PanelController
        let clock = FakeClock()

        private init(folder: URL, assembly: Assembly, panel: PanelController) {
            self.folder = folder
            self.assembly = assembly
            self.panel = panel
        }

        static func make() async throws -> Launcher {
            let folder = FileManager.default.temporaryDirectory.appending(path: "app-link-safety-\(UUID().uuidString)")
            _ = NSApplication.shared
            let surface = LauncherSurface(visibleFrame: ScenarioRunTests.offscreen)
            surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
            let configuration = Assembly.Configuration(
                environment: .scenario, dataRoot: folder, workspace: { RecordingWorkspace(wrapping: $0) },
                surface: surface)
            let assembly = Assembly(configuration)
            await assembly.start(prewarm: true)
            let panel = try #require(assembly.panel)
            panel.summoner.takesKeyStatus = false
            panel.summoner.followsPointerScreen = false
            #expect(await SelfTest.within(.seconds(20)) { await assembly.ready() })
            let launcher = Launcher(folder: folder, assembly: assembly, panel: panel)
            assembly.links.clock = launcher.clock
            return launcher
        }

        @discardableResult
        func link(_ rest: String) throws -> DeepLinkRouter.Outcome {
            assembly.links.handle(try #require(URL(string: Brand.urlScheme + "://" + rest)))
        }

        func press(_ command: QueryCommand) {
            _ = panel.queryField(panel.surface.queryField, perform: command)
        }

        func pressReturn() {
            press(.submit([]))
        }

        /// Waits until the panel has nothing loading or running, ten seconds at most.
        func settle() async {
            for _ in 0..<5 { await Task.yield() }
            await until { self.panel.isIdle }
        }

        /// Waits for a condition, checking every 5 ms, ten seconds at most.
        func until(_ condition: @MainActor () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(condition(), "a condition did not hold within 10 s")
        }

        var launched: [String] { assembly.recordingWorkspace?.launchedBundleIDs ?? [] }
        var lastHUD: String? { assembly.recordingHUD?.shown.last?.title }
        var topTitle: String? { panel.top.title }
        var visible: Bool { panel.isPanelVisible }
        var inLinkSession: Bool { panel.isLinkSession(panel.sessionID) }
        var atRoot: Bool { panel.top === panel.rootPage }

        func close() async {
            panel.summoner.dismiss(returnFocus: false)
            await assembly.shutdown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static let askRows = ["Run Running Applications", "Always Allow", "Cancel"]
    static let running = ItemID.command(feature: "apps", command: "running")

    @Test func aSearchLinkSelectsNoRowUntilTheUserMoves() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        #expect(try launcher.link("search?q=notes") == .openedLauncher(query: "notes"))
        #expect(launcher.visible)
        #expect(panel.surface.queryField.text == "notes")
        #expect(panel.shownTitles.first == "Notes")
        #expect(panel.selectedTitle == nil)

        // Return and Command-1 run nothing the link chose.
        launcher.pressReturn()
        launcher.press(.chord(KeyChord("1", .command)))
        await launcher.settle()
        #expect(launcher.launched.isEmpty)
        #expect(launcher.visible)

        // A late section keeps the selection empty.
        panel.rootPage.reload()
        #expect(panel.selectedTitle == nil)

        // Down picks the first row, and Return opens it.
        launcher.press(.moveDown)
        #expect(panel.selectedTitle == "Notes")
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.launched.count == 1)
        await launcher.close()
    }

    @Test func typingAfterASearchLinkSelectsAsUsual() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("search?q=note")
        #expect(panel.selectedTitle == nil)
        panel.surface.queryField.text = "notes"
        panel.queryField(panel.surface.queryField, didChangeText: "notes")
        #expect(panel.selectedTitle == "Notes")
        await launcher.close()
    }

    @Test func aCommandLinkSelectsCancelAndRunsNothingForASecond() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        #expect(try launcher.link("commands/apps/running") == .asked(Self.running))
        await launcher.until { panel.shownTitles == Self.askRows }
        #expect(panel.selectedTitle == "Cancel")
        #expect(launcher.inLinkSession)

        // Run and Always Allow do nothing before the page has shown for a second.
        launcher.press(.moveUp)
        launcher.press(.moveUp)
        #expect(panel.selectedTitle == "Run Running Applications")
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.topTitle == "Open Link")
        #expect(panel.surface.actionBar.toast?.text.contains("Wait") == true)
        launcher.press(.moveDown)
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.assembly.links.alwaysAllowed.isEmpty)
        #expect(launcher.topTitle == "Open Link")

        // A second later Run runs it.
        launcher.clock.advance(by: .seconds(1))
        launcher.press(.moveUp)
        launcher.pressReturn()
        await launcher.settle()
        #expect(panel.shownTitles == ["Mail", "Notes"])
        await launcher.close()
    }

    @Test func cancelWorksAtOnce() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == Self.askRows }
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.atRoot)
        await launcher.close()
    }

    @Test func aSecondLinkStartsTheWaitAgain() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == Self.askRows }
        launcher.clock.advance(by: .seconds(5))
        launcher.press(.moveUp)
        launcher.press(.moveUp)
        #expect(panel.selectedTitle == "Run Running Applications")

        // Another link swaps the page just before the user presses Return.
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == Self.askRows && panel.selectedTitle != nil }
        #expect(panel.selectedTitle == "Cancel")
        launcher.press(.moveUp)
        launcher.press(.moveUp)
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.topTitle == "Open Link")

        launcher.clock.advance(by: .seconds(1))
        launcher.pressReturn()
        await launcher.settle()
        #expect(panel.shownTitles == ["Mail", "Notes"])
        await launcher.close()
    }

    @Test func thePageWaitsAgainWhenThePanelOpensOnIt() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == Self.askRows }
        launcher.clock.advance(by: .seconds(5))
        panel.dismiss()
        panel.summon()
        await launcher.until { launcher.topTitle == "Open Link" }
        for _ in 0..<5 { await Task.yield() }
        launcher.press(.moveUp)
        launcher.press(.moveUp)
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.topTitle == "Open Link")
        await launcher.close()
    }

    @Test func alwaysAllowCoversOnlyTheArgumentsTheUserSaw() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        let volume = ItemID.command(feature: "system", command: "set-volume")
        #expect(try launcher.link("commands/system/set-volume?level=40") == .asked(volume))
        await launcher.until { panel.shownTitles.contains("Always Allow") }
        launcher.press(.moveUp)
        #expect(panel.selectedTitle == "Always Allow")
        let detail = (panel.top as? ListPageController)?.selectedRow?.subtitle
        #expect(detail == "Run Set Volume from links with exactly these arguments, without asking")
        launcher.clock.advance(by: .seconds(1))
        launcher.pressReturn()
        await launcher.settle()

        #expect(try launcher.link("commands/system/set-volume?level=40") == .ran(volume))
        // Another page cannot reuse the allowance with arguments of its own.
        #expect(try launcher.link("commands/system/set-volume?level=100") == .asked(volume))
        #expect(try launcher.link("commands/system/set-volume") == .asked(volume))
        await launcher.close()
    }

    @Test func aPasteAfterALinkOnlyCopies() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        let assembly = launcher.assembly
        await assembly.runtime.preferences.setEnabled(true, feature: "clipboard")
        _ = await SelfTest.within(.seconds(20)) { await assembly.runtime.waitUntilFeaturesAreReady() }
        await assembly.platform.copyAsAnotherApp("a synthetic copy")
        #expect(await ScenarioMode.waitForHistory("a synthetic copy", assembly: assembly) == nil)

        // The page opens Clipboard History and the user presses Return twice.
        try launcher.link("search?q=clipboard%20history")
        launcher.press(.moveDown)
        #expect(panel.selectedTitle == "Clipboard History")
        launcher.pressReturn()
        await launcher.settle()
        await launcher.until { panel.shownTitles == ["a synthetic copy"] }
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.lastHUD == "Copied, Not Pasted")
        #expect(await assembly.services.pasteboard.recentText(offset: 0) == "a synthetic copy")

        // In a session the user opened, the same paste goes through.
        panel.dismiss()
        panel.popToRoot()
        panel.summon()
        #expect(!launcher.inLinkSession)
        panel.surface.queryField.text = "clipboard history"
        panel.queryField(panel.surface.queryField, didChangeText: "clipboard history")
        #expect(panel.selectedTitle == "Clipboard History")
        launcher.pressReturn()
        await launcher.settle()
        await launcher.until { panel.shownTitles == ["a synthetic copy"] }
        let hudsBefore = assembly.recordingHUD?.shown.count ?? 0
        launcher.pressReturn()
        await launcher.settle()
        #expect(!launcher.visible)
        #expect((assembly.recordingHUD?.shown.count ?? 0) == hudsBefore)
        await launcher.close()
    }
}
