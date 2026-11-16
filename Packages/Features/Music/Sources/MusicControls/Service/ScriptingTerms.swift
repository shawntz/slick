/// Four-character codes, as numbers and as text.
nonisolated enum FourCC {
    /// The number for a code a dictionary names, such as "pPlS". Reads at most four bytes.
    static func code(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A code as text, such as "kPSP" for the number an enumerator came back as.
    static func text(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// True when the text is a code a dictionary can hold: four printable ASCII characters.
    static func isValid(_ text: String) -> Bool {
        text.utf8.count == 4 && text.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}

/// An Apple Event's class and ID, each a four-character code from a scripting dictionary.
nonisolated struct EventCode: Hashable, Sendable {
    var eventClass: String
    var eventID: String

    init(_ eventClass: String, _ eventID: String) {
        self.eventClass = eventClass
        self.eventID = eventID
    }
}

/// The scripting terms the feature sends to one player, as the four-character codes in the
/// player's scripting dictionary. Every code the live service sends is here, once, with the term
/// it stands for, so a change in a player's dictionary is fixed in one place.
///
/// Music's codes were checked against `com.apple.Music.sdef` in Music's resources on macOS 27.2.
/// Spotify's come from its dictionary as known, and were not checked against an installed copy.
nonisolated struct ScriptingTerms: Hashable, Sendable {
    /// The "playpause" command.
    var playPause: EventCode
    /// The "pause" command.
    var pause: EventCode
    /// The "next track" command.
    var nextTrack: EventCode
    /// The "previous track" command.
    var previousTrack: EventCode

    /// The application's "player state" property.
    var playerState: String
    /// The application's "player position" property, in seconds.
    var playerPosition: String
    /// The application's "current track" property.
    var currentTrack: String

    /// The track's "name" property.
    var trackName: String
    /// The track's "artist" property.
    var trackArtist: String
    /// The track's "album" property.
    var trackAlbum: String
    /// The track's "duration" property, in ``durationUnit`` seconds.
    var trackDuration: String
    /// How many seconds one unit of ``trackDuration`` is: 1 for Music, which counts seconds, and
    /// 0.001 for Spotify, which counts milliseconds.
    var durationUnit: Double

    /// The "player state" enumerators, by what they mean.
    var playingStates: Set<String>
    var pausedStates: Set<String>

    /// The event for one transport command.
    func event(for transport: Transport) -> EventCode {
        switch transport {
        case .playPause: playPause
        case .pause: pause
        case .next: nextTrack
        case .previous: previousTrack
        }
    }

    /// What a "player state" enumerator means. Stopped, and anything this list does not know.
    func state(forEnumerator code: String) -> PlaybackState {
        if playingStates.contains(code) { return .playing }
        if pausedStates.contains(code) { return .paused }
        return .stopped
    }

    /// From Music's scripting dictionary, `com.apple.Music.sdef`.
    static let music = ScriptingTerms(
        // "playpause": toggle the playing/paused state of the current track.
        playPause: EventCode("hook", "PlPs"),
        // "pause": pause playback.
        pause: EventCode("hook", "Paus"),
        // "next track": advance to the next track in the current playlist.
        nextTrack: EventCode("hook", "Next"),
        // "previous track": return to the previous track in the current playlist. The "back track"
        // event, hookBack, restarts the current track first, and the command's title promises the
        // previous track.
        previousTrack: EventCode("hook", "Prev"),
        // "player state" of application, of type ePlS.
        playerState: "pPlS",
        // "player position" of application, a real number of seconds.
        playerPosition: "pPos",
        // "current track" of application.
        currentTrack: "pTrk",
        // "name" of item, which track inherits.
        trackName: "pnam",
        // "artist" of track.
        trackArtist: "pArt",
        // "album" of track.
        trackAlbum: "pAlb",
        // "duration" of track, a real number of seconds.
        trackDuration: "pDur",
        durationUnit: 1,
        // The ePlS enumerators kPSP for "playing", kPSF for "fast forwarding" and kPSR for
        // "rewinding" all end in play.
        playingStates: ["kPSP", "kPSF", "kPSR"],
        // The ePlS enumerator kPSp for "paused". kPSS for "stopped", and anything else, reads as
        // stopped.
        pausedStates: ["kPSp"])

    /// From Spotify's scripting dictionary, `Spotify.sdef`, as known. Not checked against an
    /// installed copy: run `sdef` on Spotify before the first live use.
    static let spotify = ScriptingTerms(
        // "playpause": toggle play/pause.
        playPause: EventCode("spfy", "PlPs"),
        // "pause": pause playback.
        pause: EventCode("spfy", "Paus"),
        // "next track": skip to the next track.
        nextTrack: EventCode("spfy", "Next"),
        // "previous track": skip to the previous track.
        previousTrack: EventCode("spfy", "Prev"),
        // "player state" of application, of type ePlS.
        playerState: "pPlS",
        // "player position" of application, a real number of seconds.
        playerPosition: "pPos",
        // "current track" of application.
        currentTrack: "pTrk",
        // "name" of track.
        trackName: "pnam",
        // "artist" of track.
        trackArtist: "pArt",
        // "album" of track.
        trackAlbum: "pAlb",
        // "duration" of track, an integer number of milliseconds.
        trackDuration: "pDur",
        durationUnit: 0.001,
        // The ePlS enumerator kPSP for "playing".
        playingStates: ["kPSP"],
        // The ePlS enumerator kPSp for "paused". kPSS for "stopped", and anything else, reads as
        // stopped.
        pausedStates: ["kPSp"])
}

extension Player {
    /// The terms this player's dictionary defines.
    nonisolated var terms: ScriptingTerms {
        switch self {
        case .music: .music
        case .spotify: .spotify
        }
    }
}
