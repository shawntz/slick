import Foundation
import Kit

/// Media Controls: play, pause and skip in Apple's Music app and in Spotify from the launcher.
///
/// - Five commands: Play or Pause, Pause, Next Track, Previous Track and Now Playing. Each closes the panel
///   with a HUD that says what happened, such as the new track's title. See `TransportCommands.swift`.
/// - The players sit behind ``PlayerService``, named by ``PlayerServiceKey``: Apple Events to the
///   running app in the launcher, a simulated queue in tests, scenarios, self-tests and benchmarks.
/// - Which player: the one that runs; when both run, the one that plays. When neither runs, the
///   command offers to open the preferred one and starts nothing until the user says so. See
///   ``PlayerChooser``.
/// - Play or Pause shows the current track as a live subtitle while its row is on screen, asking
///   the players at most once every two seconds, off the main thread. See ``NowPlayingMonitor``.
/// - Two hotkey presets for the transport commands. Nothing is bound until the user applies one.
/// - Activation does nothing: no player is asked anything until a command runs or the row shows.
public final class MediaControlsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "media", name: Strings.featureName, icon: .symbol("playpause"), summary: Strings.featureSummary,
        permissions: [
            PermissionNeed(Player.music.permission, reason: Strings.Reasons.music),
            PermissionNeed(Player.spotify.permission, reason: Strings.Reasons.spotify),
        ])

    let context: FeatureContext
    let players: any PlayerService
    let monitor: NowPlayingMonitor

    /// Does no I/O. The service touches nothing until a command runs or the row shows.
    public init(context: FeatureContext) {
        self.context = context
        players = context.service(PlayerServiceKey.self)
        monitor = NowPlayingMonitor(players: players, clock: context.clock, settings: context.settings)
    }

    public var commands: [Command] {
        [playPauseCommand, pauseCommand, nextCommand, previousCommand, nowPlayingCommand]
    }

    public var hotkeyPresets: [HotkeyPreset] { MediaHotkeyPresets.all }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.Settings.playerSection,
                items: [
                    .picker(
                        Strings.Settings.preferredPlayer, key: MediaSettings.preferredPlayer,
                        info: Strings.Settings.preferredPlayerInfo, titles: Strings.Settings.playerOption),
                    .note(Strings.Settings.accessNote),
                    .note(Strings.Settings.privacyNote),
                    .permission(Player.music.permission),
                    .permission(Player.spotify.permission),
                ]),
            SettingsSection(
                Strings.Settings.hotkeysSection,
                items: [.note(Strings.Settings.noHotkeysNote), .note(Strings.Settings.functionKeysNote)]),
        ])
    }
}
