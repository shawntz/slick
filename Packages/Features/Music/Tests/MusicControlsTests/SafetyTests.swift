import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Safety", .timeLimit(.minutes(1)))
@MainActor
struct SafetyTests {
    @Test func activatingTheFeatureTouchesNothing() async throws {
        let media = MediaHarness()
        await media.harness.activate()
        try await media.harness.settle()
        await media.harness.deactivate()
        await media.harness.activate()
        try await media.harness.settle()
        #expect(media.players.requests.isEmpty, "not even the list of running apps")
        #expect(media.fakes.permissions.requests.isEmpty)
        #expect(media.fakes.permissions.openStreamCount == 0)
        #expect(media.fakes.hotkeys.registered.isEmpty)
        #expect(media.fakes.workspace.launched.isEmpty)
        #expect(media.fakes.workspace.opened.isEmpty)
        #expect(media.fakes.processes.runs.isEmpty)
        #expect(media.harness.huds.isEmpty && media.harness.toasts.isEmpty)
    }

    /// The live service is never run here. Its send options are a constant, so the rule that a
    /// send can never prompt and never interacts is checked on the value alone.
    @Test func everyLiveSendRefusesToPromptAndWaitsBriefly() {
        let options = LivePlayers.sendOptions
        // kAEDoNotPromptForUserConsent in the SDK's AppleEvents.h.
        #expect(options.rawValue & 0x0002_0000 != 0)
        #expect(options.contains(.waitForReply))
        #expect(options.contains(.neverInteract))
        #expect(!options.contains(.canInteract))
        #expect(LivePlayers.timeout == 3)
    }

    @Test func readingTheDeclarationsTouchesNothing() throws {
        let media = MediaHarness()
        _ = media.feature.commands
        _ = media.feature.settingsPane
        _ = media.feature.hotkeyPresets
        _ = try media.subtitle()
        #expect(media.players.requests.isEmpty)
    }

    @Test func nowPlayingOnlyReads() async throws {
        let media = MediaHarness([.music: MediaHarness.playing(SimulatedPlayers.musicQueue)])
        for _ in 0..<3 {
            try await media.harness.run("now-playing")
        }
        #expect(media.players.sent.isEmpty)
        #expect(media.players.app(.music)?.state == .playing)
        #expect(media.players.app(.music)?.index == 0)
    }

    @Test func turningTheFeatureOffLeavesNoWorkBehind() async throws {
        let media = MediaHarness()
        await media.harness.activate()
        _ = try await media.subtitleText()
        try await media.harness.run("play-pause")
        await media.harness.deactivate()
        let before = media.players.requests
        media.clock.advance(by: .seconds(120))
        try await media.harness.settle()
        #expect(media.players.requests == before)
        #expect(media.clock.sleeperCount == 0)
    }
}
