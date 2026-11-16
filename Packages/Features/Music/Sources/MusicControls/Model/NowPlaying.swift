/// Whether a player plays.
nonisolated enum PlaybackState: String, Hashable, Sendable {
    /// Playing, or moving through the track fast, which ends in playing.
    case playing
    case paused
    /// Stopped, or idle with nothing to play.
    case stopped
}

/// One track, as the player describes it. The texts are the player's own, so they go through
/// ``TrackText`` before anyone reads them.
nonisolated struct Track: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    /// The length in seconds. Nil for a radio stream, or when the player gave none.
    var duration: Double?

    init(title: String, artist: String = "", album: String = "", duration: Double? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// What one player does now.
nonisolated struct NowPlaying: Hashable, Sendable {
    var player: Player
    var state: PlaybackState
    /// Nil when the player has no current track, as when it is stopped with nothing queued.
    var track: Track?
    /// Seconds into the track. Nil when the player gave none.
    var position: Double?

    init(player: Player, state: PlaybackState, track: Track? = nil, position: Double? = nil) {
        self.player = player
        self.state = state
        self.track = track
        self.position = position
    }

    var isPlaying: Bool { state == .playing }
}

/// The three commands a player takes.
nonisolated enum Transport: String, Hashable, Sendable, CaseIterable {
    /// Pauses a player that plays, and plays one that does not.
    case playPause
    /// Pauses a player that plays, and does nothing to one that does not.
    case pause
    case next
    case previous

    /// True for the commands that change the track.
    var skips: Bool { self == .next || self == .previous }
}
