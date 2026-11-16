import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Declarations", .timeLimit(.minutes(1)))
@MainActor
struct DeclarationTests {
    nonisolated static let commandIDs = ["play-pause", "pause", "next-track", "previous-track", "now-playing"]
    /// The commands that offer to open the preferred player when none runs. Pause has nothing to
    /// pause then.
    nonisolated static let offersToOpenIDs = commandIDs.filter { $0 != "pause" }

    @Test func declaresFiveCommandsAndTheValidatorFindsNothing() {
        let media = MediaHarness()
        #expect(media.feature.commands.map(\.id) == Self.commandIDs)
        #expect(
            media.feature.commands.map(\.title) == [
                "Play or Pause", "Pause", "Next Track", "Previous Track", "Now Playing",
            ])
        #expect(media.harness.issues.isEmpty)
        #expect(media.harness.pendingIssues.isEmpty)
    }

    @Test func titlesUseTitleCaseAndNoCommandSuggestsAHotkey() {
        let minorWords: Set<Substring> = ["or", "and", "by", "to", "in", "of", "from"]
        for command in MediaHarness().feature.commands {
            let words = command.title.split(separator: " ")
            #expect(
                words.allSatisfy { minorWords.contains($0) || $0.first?.isUppercase == true }, "\(command.title)")
            #expect(!command.title.hasSuffix("."))
            #expect(command.suggestedHotkey == nil)
            #expect(!command.keywords.isEmpty, "\(command.id) has keywords")
            #expect(command.confirmation == nil, "nothing here deletes or changes data")
            #expect(command.requires.isEmpty, "the permission depends on which player runs")
        }
    }

    @Test(arguments: [
        ("pause", "stop playback"), ("play-pause", "resume"), ("next-track", "skip"), ("previous-track", "back"),
        ("previous-track", "prev"), ("now-playing", "current song"), ("now-playing", "what is playing"),
    ])
    func commandsAnswerTheWordsPeopleType(id: String, word: String) throws {
        let command = try MediaHarness().harness.command(id)
        #expect(command.keywords.contains(word))
    }

    @Test func noCommandCompetesWithTheAppsForTheirOwnNames() {
        for command in MediaHarness().feature.commands {
            let words = Set(command.keywords.map { $0.lowercased() })
            #expect(words.isDisjoint(with: ["music", "spotify"]), "\(command.id)")
        }
    }

    @Test func thePaneSaysWhatTheRowAsksAndThatNothingIsWritten() throws {
        let pane = try #require(MediaHarness().feature.settingsPane)
        let notes = pane.sections.flatMap(\.items).compactMap { item -> String? in
            if case .note = item.control { return item.title }
            return nil
        }
        #expect(notes.contains { $0.contains("at most once every two seconds") })
        #expect(notes.contains { $0.contains("writes none of it to disk") })
        #expect(notes.contains { $0.contains("Nothing is sent to a player that is not running.") })
        #expect(notes.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func theManifestNamesBothPlayersWithAReasonEach() {
        let manifest = MediaControlsFeature.manifest
        #expect(manifest.id == "media")
        #expect(manifest.name == "Media Controls")
        #expect(manifest.isEnabledByDefault)
        #expect(
            manifest.permissions.map(\.permission) == [
                .automation(bundleID: "com.apple.Music"), .automation(bundleID: "com.spotify.client"),
            ])
        for need in manifest.permissions {
            #expect(need.reason.hasPrefix("Play,"), "\(need.reason)")
            #expect(need.reason.hasSuffix("."))
        }
        #expect(manifest.summary.hasSuffix("."))
    }

    @Test func onlyPlayOrPauseHasALiveSubtitleAndItRunsOffTheMainThread() throws {
        let media = MediaHarness()
        let commands = media.feature.commands
        #expect(commands.filter { $0.liveSubtitle != nil }.map(\.id) == ["play-pause"])
        let subtitle = try media.subtitle()
        #expect(subtitle.backgroundFetch != nil, "root search calls it off the main thread")
        #expect(subtitle.interval == .seconds(2))
        // The same signal on every read, so root search keeps one refresh loop.
        let again = try media.subtitle()
        #expect(subtitle.changes === again.changes)
        #expect(subtitle.changes === media.feature.monitor.changes)
    }

    @Test func everyCommandMayRunFromADeepLinkAndTheValidatorAgrees() {
        let media = MediaHarness()
        for command in media.feature.commands {
            #expect(command.allowsDeepLinks, "\(command.id)")
            #expect(command.showsInRoot, "\(command.id)")
        }
        #expect(FeatureValidator.validate(media.feature).isEmpty)
        #expect(FeatureValidator.pendingIssues(media.feature).isEmpty)
    }

    @Test func theSettingsPaneOffersThePreferredPlayerWithMusicFirst() throws {
        let media = MediaHarness()
        let pane = try #require(media.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Player", "Hotkeys"])
        let keys = pane.sections.flatMap(\.items).compactMap(\.control.key?.name)
        #expect(keys == ["preferredPlayer"])
        #expect(media.settings[MediaSettings.preferredPlayer] == .music)
        let picker = try #require(pane.sections.first?.items.first)
        guard case .picker(_, let options) = picker.control else {
            Issue.record("the first item is not a picker")
            return
        }
        #expect(options.map(\.title) == ["Music", "Spotify"])
        #expect(options.map(\.value) == [.string("music"), .string("spotify")])
        #expect(picker.title == "Preferred player")
        #expect(picker.info?.hasSuffix(".") == true)
    }

    @Test func choosingSpotifyInSettingsIsStoredWithoutAQuestion() throws {
        let media = MediaHarness()
        #expect(try media.harness.chooseSetting("Preferred player", option: "Spotify"))
        #expect(media.settings[MediaSettings.preferredPlayer] == .spotify)
        #expect(media.harness.confirmations.isEmpty, "the choice deletes nothing")
    }

    @Test func aStoredPlayerOfTheWrongKindReadsAsMusic() {
        let media = MediaHarness()
        media.fakes.settings.set(.string("example-player"), for: "media.preferredPlayer")
        #expect(media.settings[MediaSettings.preferredPlayer] == .music)
        media.fakes.settings.set(.int(3), for: "media.preferredPlayer")
        #expect(media.settings[MediaSettings.preferredPlayer] == .music)
    }

    @Test func thePresetsBindOnlyTheTransportCommandsAndNothingIsBound() async throws {
        let media = MediaHarness()
        await media.harness.activate()
        let presets = media.feature.hotkeyPresets
        #expect(presets.map(\.id) == ["function-keys", "control-option-command"])
        #expect(presets.map(\.name) == ["Function Keys", "Control, Option and Command"])
        for preset in presets {
            #expect(Set(preset.bindings.keys) == ["play-pause", "next-track", "previous-track"])
            #expect(Set(preset.bindings.values).count == preset.bindings.count)
            #expect(!preset.bindings.values.contains(KeyCombo(.space, .command)), "the launcher's own hotkey")
        }
        #expect(MediaHotkeyPresets.functionKeys.bindings["previous-track"]?.displayString == "F7")
        #expect(MediaHotkeyPresets.functionKeys.bindings["play-pause"]?.displayString == "F8")
        #expect(MediaHotkeyPresets.functionKeys.bindings["next-track"]?.displayString == "F9")
        #expect(MediaHotkeyPresets.controlOptionCommand.bindings["play-pause"]?.displayString == "⌃⌥⌘Space")
        #expect(MediaHotkeyPresets.controlOptionCommand.bindings["previous-track"]?.displayString == "⌃⌥⌘[")
        #expect(MediaHotkeyPresets.controlOptionCommand.bindings["next-track"]?.displayString == "⌃⌥⌘]")
        #expect(media.fakes.hotkeys.registered.isEmpty, "offered, never applied")
        #expect(media.feature.commands.allSatisfy { $0.suggestedHotkey == nil })
    }

    @Test func everyRunOutsideTheAppGetsTheSimulatedPlayers() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let context = FakeServices().context(featureID: "media", environment: environment)
            #expect(context.service(PlayerServiceKey.self) is SimulatedPlayers, "\(environment)")
        }
        let harness = FeatureHarness(MediaControlsFeature.self)
        #expect(harness.feature.players is SimulatedPlayers, "a harness made without an override")
    }

    @Test func theScenarioSampleHasMusicPausedAndSpotifyClosed() async throws {
        let sample = SimulatedPlayers.sample()
        #expect(await sample.runningPlayers() == [.music])
        let music = try await sample.status(of: .music)
        #expect(music.state == .paused)
        #expect(music.track?.title == "Example Song One")
        #expect(music.position == 83)
        await #expect(throws: PlayerFailure.notRunning(.spotify)) { try await sample.status(of: .spotify) }
    }

    /// A scenario quits Music through a setting the live players never read, so it can show the
    /// question that comes before a player opens.
    @Test func aScenarioCanQuitTheSimulatedMusic() async throws {
        let fakes = FakeServices()
        let context = fakes.context(featureID: "media", environment: .scenario)
        let players = try #require(context.service(PlayerServiceKey.self) as? SimulatedPlayers)
        #expect(await players.runningPlayers() == [.music])
        context.settings[MediaSettings.simulatedQuit] = "com.apple.Music"
        #expect(await players.runningPlayers().isEmpty)
        await #expect(throws: PlayerFailure.notRunning(.music)) { try await players.status(of: .music) }
        await #expect(throws: PlayerFailure.notRunning(.music)) { try await players.send(.playPause, to: .music) }
        #expect(players.sent.isEmpty)
        context.settings[MediaSettings.simulatedQuit] = ""
        #expect(await players.runningPlayers() == [.music])
    }
}
