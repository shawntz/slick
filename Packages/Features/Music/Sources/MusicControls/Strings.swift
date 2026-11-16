import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
/// Command, section, HUD, toast and button titles use title case, as macOS menus do. Everything
/// else is a plain sentence that says what will happen or what happened. Track, artist and album
/// names are the player's own and go through ``TrackText`` first.
nonisolated enum Strings {
    // MARK: - Feature

    static let featureName = "Media Controls"
    static let featureSummary = "Play, pause and skip tracks in Music and Spotify, and see what is playing."

    enum Players {
        static let music = "Music"
        static let spotify = "Spotify"
    }

    // MARK: - Commands

    enum Commands {
        static let playPause = "Play or Pause"
        // No command lists "music" or "spotify" as a keyword: those words open the apps, and a
        // keyword match could outrank an app's own row once the command is used often.
        static let playPauseKeywords = ["play", "resume", "playpause", "toggle playback"]
        /// Pause only pauses, so typing "pause" never starts a paused player.
        static let pause = "Pause"
        static let pauseKeywords = ["stop playback", "pause music", "pause song"]
        static let next = "Next Track"
        static let nextKeywords = ["next", "skip", "forward", "next song"]
        static let previous = "Previous Track"
        static let previousKeywords = ["previous", "prev", "back", "previous song", "last song"]
        static let nowPlaying = "Now Playing"
        static let nowPlayingKeywords = ["current track", "current song", "what is playing", "song info", "track info"]
    }

    // MARK: - What happened

    /// The HUD after a transport command, from what the player does once the command ran.
    static func done(_ transport: Transport, now: NowPlaying) -> String {
        let player = now.player.name
        guard let track = now.track else {
            switch transport {
            case .playPause: return now.isPlaying ? "Playing in \(player)" : "Nothing to Play in \(player)"
            case .pause: return now.isPlaying ? "Playing in \(player)" : "Paused \(player)"
            case .next, .previous: return "No More Tracks in \(player)"
            }
        }
        let described = TrackText.describe(track)
        if now.isPlaying { return "Playing \(described)" }
        switch transport {
        case .playPause, .pause: return "Paused \(described)"
        case .next: return "Skipped to \(described)"
        case .previous: return "Went Back to \(described)"
        }
    }

    /// The HUD of Pause when no player runs.
    static let notPlaying = "Nothing Is Playing"

    /// The HUD of Pause when the player it found does not play, so nothing was sent.
    static func notPlaying(_ now: NowPlaying) -> String {
        guard now.track != nil, now.state == .paused else { return "Nothing Is Playing in \(now.player.name)" }
        return "\(now.player.name) Is Already Paused"
    }

    /// The HUD of Now Playing: the track and its artist, the album, the player and the time, in one
    /// line.
    static func nowPlaying(_ now: NowPlaying) -> String {
        let player = now.player.name
        guard let track = now.track, now.state != .stopped else { return "Nothing Is Playing in \(player)" }
        var parts = [TrackText.describe(track)]
        if let album = TrackText.clean(track.album, limit: TrackText.nameLimit) { parts.append(album) }
        parts.append(now.isPlaying ? "Playing in \(player)" : "Paused in \(player)")
        if let time = TrackText.progress(position: now.position, duration: track.duration) { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    /// The time in the track and its length, as in "1:23 of 4:56".
    static func progress(_ position: String, of duration: String) -> String {
        "\(position) of \(duration)"
    }

    static let untitledTrack = "Untitled Track"

    // MARK: - Live subtitle

    /// The Play or Pause row's subtitle. Short, without a full stop, as row subtitles are.
    enum Subtitle {
        static let noPlayer = "No player is running"

        static func playing(_ track: Track, in player: Player) -> String {
            "Playing \(TrackText.describe(track)) in \(player.name)"
        }

        static func paused(_ track: Track, in player: Player) -> String {
            "Paused on \(TrackText.describe(track)) in \(player.name)"
        }

        static func idle(_ player: Player) -> String {
            "Nothing is playing in \(player.name)"
        }

        static func needsAccess(_ player: Player) -> String {
            "Run it once to allow control of \(player.name)"
        }

        static func silent(_ player: Player) -> String {
            "\(player.name) did not answer"
        }
    }

    // MARK: - No player

    enum Open {
        static func question(_ player: Player) -> String {
            "Open \(player.name)?"
        }

        static func message(_ player: Player) -> String {
            "No player is running. \(player.name) is your preferred player, and you can choose another in settings."
        }

        static func confirm(_ player: Player) -> String {
            "Open \(player.name)"
        }

        static func opened(_ player: Player) -> String {
            "Opened \(player.name)"
        }

        static func failed(_ player: Player) -> String {
            "Could Not Open \(player.name)"
        }

        static func failedMessage(_ player: Player) -> String {
            "\(player.name) may not be installed. Choose another preferred player in settings."
        }
    }

    // MARK: - Failures

    enum Failure {
        static func notRunning(_ player: Player) -> String {
            "\(player.name) Is Not Running"
        }

        static let notRunningMessage = "It quit before the command reached it."

        static func timedOut(_ player: Player) -> String {
            "\(player.name) Did Not Answer"
        }

        static let timedOutMessage = "Try again in a moment."

        static func failed(_ player: Player) -> String {
            "Could Not Control \(player.name)"
        }

        static func code(_ code: Int32) -> String {
            "macOS returned error \(code)."
        }
    }

    // MARK: - Settings

    enum Settings {
        static let playerSection = "Player"
        static let preferredPlayer = "Preferred player"
        static let preferredPlayerInfo =
            "When no player is running, the commands offer to open this one. When both are open and neither plays, they control this one."

        static func playerOption(_ player: Player) -> String {
            player.name
        }

        static let privacyNote =
            "While the Play or Pause row is on screen, the launcher asks the running player what it plays, at most once every two seconds. This feature keeps the answer in memory and writes none of it to disk."

        static let hotkeysSection = "Hotkeys"
        static let noHotkeysNote =
            "Play or Pause, Next Track and Previous Track have no hotkeys until you add them. A preset above sets all three at once."
        static let functionKeysNote =
            "The Function Keys preset works when the keys send F7, F8 and F9, which is when you hold Fn or set them to act as standard function keys in Keyboard settings."
        static let accessNote =
            "The first time a command finds Music or Spotify running, the launcher says why it needs permission to control that app, and macOS asks only after you press Grant Access. Nothing is sent to a player that is not running."
    }

    // MARK: - Hotkey presets

    enum Presets {
        static let functionKeys = "Function Keys"
        static let controlOptionCommand = "Control, Option and Command"
    }

    // MARK: - Permission reasons

    enum Reasons {
        static let music = "Play, pause and skip tracks in Music, and read what is playing."
        static let spotify = "Play, pause and skip tracks in Spotify, and read what is playing."
    }
}
