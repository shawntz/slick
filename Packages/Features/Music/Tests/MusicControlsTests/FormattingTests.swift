import Foundation
import Kit
import KitTesting
import Testing

@testable import MusicControls

@Suite("Odd input", .timeLimit(.minutes(1)))
@MainActor
struct FormattingTests {
    @Test(arguments: [
        (0.0, "0:00"), (5.9, "0:05"), (65, "1:05"), (600, "10:00"), (3_599, "59:59"), (3_600, "1:00:00"),
        (3_723, "1:02:03"), (359_999, "99:59:59"),
    ])
    func timesReadAsAPlayerShowsThem(seconds: Double, text: String) {
        #expect(TrackText.time(seconds) == text)
    }

    @Test(arguments: [-1, Double.nan, .infinity, -.infinity, 360_000, 1e300])
    func timesNoTrackHasShowNothing(seconds: Double) {
        #expect(TrackText.time(seconds) == nil)
    }

    @Test func progressShowsThePositionAndTheLength() {
        #expect(TrackText.progress(position: 83, duration: 245) == "1:23 of 4:05")
        #expect(TrackText.progress(position: 83, duration: nil) == "1:23", "a stream has no length")
        #expect(TrackText.progress(position: 83, duration: 0) == "1:23")
        #expect(TrackText.progress(position: 300, duration: 245) == "4:05 of 4:05", "a moment past the end")
        #expect(TrackText.progress(position: nil, duration: 245) == nil)
        #expect(TrackText.progress(position: .nan, duration: 245) == nil)
        #expect(TrackText.progress(position: 10, duration: .infinity) == "0:10")
    }

    @Test func namesComeOutOnOneLineInTheOrderTheyAreStored() {
        #expect(TrackText.clean("Line One\nLine Two", limit: 60) == "Line One Line Two")
        #expect(TrackText.clean("  Padded  ", limit: 60) == "Padded")
        #expect(TrackText.clean("song\u{202E}3pm", limit: 60) == "song\u{FFFD}3pm")
        #expect(TrackText.clean("A\u{2028}B\u{0000}C", limit: 60) == "A B C")
    }

    @Test(arguments: ["", " ", "\n\t", "\u{200B}", "\u{200B}\u{2060}\u{FEFF}", "\u{202E}"])
    func aNameThatShowsNothingIsNoName(text: String) {
        if text == "\u{202E}" {
            // A lone override becomes a visible replacement mark.
            #expect(TrackText.clean(text, limit: 60) == "\u{FFFD}")
        } else {
            #expect(TrackText.clean(text, limit: 60) == nil)
        }
    }

    @Test func longNamesAreCutWithAnEllipsis() throws {
        let long = String(repeating: "a", count: 100)
        let cut = try #require(TrackText.clean(long, limit: 60))
        #expect(cut.count == 60)
        #expect(cut.hasSuffix("…"))
        #expect(TrackText.clean(String(repeating: "b", count: 60), limit: 60)?.count == 60, "exactly the limit")
    }

    @Test func aHugeNameIsReadOnlyAsFarAsItCanShow() throws {
        let huge = String(repeating: "x", count: 1_000_000)
        let cut = try #require(TrackText.clean(huge, limit: 40))
        #expect(cut.count == 40)
        // One character with a million combining marks: the work stays bounded and the result short.
        let marks = "e" + String(repeating: "\u{0301}", count: 1_000_000)
        let shown = try #require(TrackText.clean(marks, limit: 40))
        #expect(shown.unicodeScalars.count <= 40 * 8 + 1)
        #expect(shown.hasSuffix("…"))
    }

    @Test func emojiAndOtherScriptsStayWhole() {
        #expect(TrackText.clean("Café 👩‍👩‍👧 曲", limit: 60) == "Café 👩‍👩‍👧 曲")
        #expect(TrackText.clean("أغنية", limit: 60) == "أغنية")
    }

    @Test func aTrackWithoutAnArtistOrATitleStillReads() {
        #expect(TrackText.describe(Track(title: "Only Title")) == "“Only Title”")
        #expect(TrackText.describe(Track(title: "", artist: "Example Artist")) == "“Untitled Track” by Example Artist")
        #expect(TrackText.describe(Track(title: "\u{200B}", artist: " ")) == "“Untitled Track”")
        let multiline = Track(title: "Two\nLines", artist: "Some\u{202E}one")
        #expect(TrackText.describe(multiline) == "“Two Lines” by Some\u{FFFD}one")
    }

    @Test func nowPlayingLeavesOutWhatThePlayerDidNotGive() {
        let bare = NowPlaying(player: .spotify, state: .playing, track: Track(title: "Ad"))
        #expect(Strings.nowPlaying(bare) == "“Ad” · Playing in Spotify")
        let stream = NowPlaying(
            player: .music, state: .playing, track: Track(title: "Example Station", album: " "), position: 754)
        #expect(Strings.nowPlaying(stream) == "“Example Station” · Playing in Music · 12:34")
    }

    @Test func hudsNeverBreakOverLines() {
        let odd = Track(title: "First\nSecond", artist: "A\rB", album: "C\u{2029}D", duration: 100)
        let now = NowPlaying(player: .music, state: .paused, track: odd, position: 10)
        for text in [
            Strings.done(.playPause, now: now), Strings.done(.next, now: now), Strings.nowPlaying(now),
            Strings.Subtitle.paused(odd, in: .music),
        ] {
            #expect(!text.contains { $0.isNewline }, "\(text)")
        }
    }

    @Test func spotifyCountsMillisecondsAndMusicSeconds() {
        #expect(Player.music.terms.durationUnit == 1)
        #expect(Player.spotify.terms.durationUnit == 0.001)
    }
}
