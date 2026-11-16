import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitTesting
import LauncherUI
import Root
import Testing

@testable import SlickApp

/// Keys a user presses for something else while a link's page shows. A link can arrive while the
/// user types in the launcher, so the rest of their word and their Return land on the page the
/// link opened. Found in review: typing a letter that "Cancel" lacks filtered Cancel out and
/// selected Run or Always Allow, Command-1 ran Run with Cancel selected, and Tab on a search link's
/// text sent that text to the Tab command.
@Suite("Link keystrokes", .serialized, .timeLimit(.minutes(3)))
@MainActor struct LinkKeystrokeTests {
    typealias Launcher = LinkSafetyTests.Launcher

    @Test func typingOnThePageThatAsksKeepsCancelSelected() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == LinkSafetyTests.askRows }
        #expect(panel.selectedTitle == "Cancel")
        // "r" is in Run's title and not in Cancel's.
        launcher.type("r")
        await launcher.settle()
        #expect(panel.shownTitles == LinkSafetyTests.askRows)
        #expect(panel.selectedTitle == "Cancel")
        launcher.clock.advance(by: .seconds(1))
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.atRoot)
        #expect(launcher.topTitle != "Running Applications")
        await launcher.close()
    }

    @Test func typingALetterOnlyAlwaysAllowHasStoresNothing() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == LinkSafetyTests.askRows }
        launcher.type("w")
        await launcher.settle()
        #expect(panel.selectedTitle == "Cancel")
        launcher.clock.advance(by: .seconds(1))
        launcher.pressReturn()
        await launcher.settle()
        #expect(launcher.assembly.links.alwaysAllowed.isEmpty)
        await launcher.close()
    }

    @Test func commandNumbersRunNoRowOfThePageThatAsks() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("commands/apps/running")
        await launcher.until { panel.shownTitles == LinkSafetyTests.askRows }
        launcher.clock.advance(by: .seconds(1))
        for key in ["1", "2", "3"] {
            launcher.press(.chord(KeyChord(key, .command)))
            await launcher.settle()
        }
        #expect(launcher.topTitle == "Open Link")
        #expect(panel.selectedTitle == "Cancel")
        #expect(launcher.assembly.links.alwaysAllowed.isEmpty)
        await launcher.close()
    }

    /// With Ask AI as the Tab command, Tab on a search link's text runs nothing.
    @Test func tabOnASearchLinksTextRunsNoTabCommand() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        launcher.assembly.general[HostSettings.tabCommand] = "cmd:ai.ask"
        for _ in 0..<10 { await Task.yield() }
        await launcher.assembly.root.settle()
        try launcher.link("search?q=say+hello")
        await launcher.settle()
        #expect(panel.selectedTitle == nil)
        launcher.press(.complete)
        await launcher.settle()
        #expect(launcher.atRoot)
        #expect(launcher.panel.runtime.pipeline.activeRunCount == 0)
        await launcher.close()
    }

    /// Ask AI run in a session a link opened, as the Tab command runs it once the user moved the
    /// selection, shows its form, so nothing reaches the provider until the user presses its
    /// button.
    @Test func askAIInALinkSessionShowsItsForm() async throws {
        let launcher = try await Launcher.make()
        let panel = launcher.panel
        try launcher.link("search?q=say+hello")
        await launcher.settle()
        #expect(launcher.inLinkSession)
        let ask = ItemID.command(feature: "ai", command: "ask")
        await panel.runtime.pipeline.runCommand(ask, typedText: "say hello", launch: .tabFromRoot).value
        await launcher.settle()
        #expect(launcher.topTitle == "Ask AI")
        #expect(panel.top is FormPageController)
        await launcher.close()
    }
}
