import Foundation
import Kit

/// Track, artist and album names made safe to show, and times written as a player shows them.
///
/// A player hands over whatever the track's tags hold: a line break, a right-to-left override, a
/// name of nothing but a zero-width space, or a name thousands of characters long. Every name goes
/// through ``clean(_:limit:)`` before it reaches a HUD or a subtitle.
nonisolated enum TrackText {
    /// The most characters of a track title shown, ellipsis included.
    static let titleLimit = 60
    /// The most characters of an artist or album name shown, ellipsis included.
    static let nameLimit = 40

    /// The text on one line, in the order it is stored, without spaces at either end, and cut to
    /// `limit` characters with an ellipsis. Nil when nothing in it shows.
    static func clean(_ text: String, limit: Int) -> String? {
        let limit = max(2, limit)
        // Only the start can show, so a very long name is read no further than that. Counting
        // scalars rather than characters bounds the work even for one huge cluster of marks.
        let scalars = text.unicodeScalars
        let head = scalars.prefix(limit * 8)
        let isCut = head.endIndex < scalars.endIndex
        let line = DisplayText.oneLine(String(String.UnicodeScalarView(head))).trimmingCharacters(in: .whitespaces)
        let visible = line.unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
        }
        guard visible else { return nil }
        guard line.count > limit || isCut else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }

    /// The title in curly quotes, as in “Example Song”, or Untitled Track when it shows nothing.
    static func quotedTitle(_ track: Track) -> String {
        "“" + (clean(track.title, limit: titleLimit) ?? Strings.untitledTrack) + "”"
    }

    /// The quoted title and the artist, as in “Example Song” by Example Artist. Without an
    /// artist, the title alone.
    static func describe(_ track: Track) -> String {
        guard let artist = clean(track.artist, limit: nameLimit) else { return quotedTitle(track) }
        return quotedTitle(track) + " by " + artist
    }

    /// Seconds as minutes and seconds, as in 4:05, or with hours, as in 1:02:03. Nil for a value
    /// no track has: negative, not a number, or 100 hours and more.
    static func time(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 360_000 else { return nil }
        let whole = Int(seconds.rounded(.down))
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        let paddedRest = rest < 10 ? "0\(rest)" : "\(rest)"
        guard hours > 0 else { return "\(minutes):\(paddedRest)" }
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(paddedMinutes):\(paddedRest)"
    }

    /// Where the player is in the track and how long the track is, as in 1:23 of 4:56. Only the
    /// position when the length is unknown, as for a stream. A position past the end, which a
    /// player can report for a moment while it changes tracks, shows as the end. Nil without a
    /// position.
    static func progress(position: Double?, duration: Double?) -> String? {
        guard let position, let at = time(position) else { return nil }
        guard let duration, duration > 0, let length = time(duration) else { return at }
        guard let clamped = time(min(position, duration)) else { return at }
        return Strings.progress(clamped, of: length)
    }
}
