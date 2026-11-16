import Foundation
import Kit
import Testing

@testable import MusicControls

/// The codes the live service sends, checked against each player's scripting dictionary as
/// written down here. Music's were read from `com.apple.Music.sdef` on macOS 27.2. Spotify's are
/// as known and wait for a check against an installed copy.
@Suite("Scripting terms", .timeLimit(.minutes(1)))
struct ScriptingTermsTests {
    @Test func musicSendsTheCodesItsDictionaryDefines() {
        let terms = ScriptingTerms.music
        #expect(terms.playPause == EventCode("hook", "PlPs"))
        #expect(terms.pause == EventCode("hook", "Paus"))
        #expect(terms.nextTrack == EventCode("hook", "Next"))
        #expect(terms.previousTrack == EventCode("hook", "Prev"))
        #expect(terms.playerState == "pPlS")
        #expect(terms.playerPosition == "pPos")
        #expect(terms.currentTrack == "pTrk")
        #expect(
            [terms.trackName, terms.trackArtist, terms.trackAlbum, terms.trackDuration] == [
                "pnam", "pArt", "pAlb", "pDur",
            ])
    }

    @Test func spotifySendsItsOwnSuite() {
        let terms = ScriptingTerms.spotify
        #expect(terms.playPause == EventCode("spfy", "PlPs"))
        #expect(terms.pause == EventCode("spfy", "Paus"))
        #expect(terms.nextTrack == EventCode("spfy", "Next"))
        #expect(terms.previousTrack == EventCode("spfy", "Prev"))
        #expect(terms.playerState == "pPlS")
        #expect(terms.currentTrack == "pTrk")
    }

    @Test(arguments: [Player.music, .spotify])
    func everyCodeIsFourPrintableCharacters(player: Player) {
        let terms = player.terms
        let events = Transport.allCases.map(terms.event(for:))
        let codes =
            events.flatMap { [$0.eventClass, $0.eventID] }
            + [
                terms.playerState, terms.playerPosition, terms.currentTrack, terms.trackName, terms.trackArtist,
                terms.trackAlbum, terms.trackDuration,
            ] + terms.playingStates + terms.pausedStates
        for code in codes {
            #expect(FourCC.isValid(code), "\(code)")
        }
        #expect(Set(events).count == Transport.allCases.count, "each command has its own event")
    }

    @Test(arguments: [
        ("kPSP", PlaybackState.playing), ("kPSp", .paused), ("kPSS", .stopped), ("kPSF", .playing),
        ("kPSR", .playing), ("????", .stopped),
    ])
    func musicStatesMeanWhatTheDictionarySays(code: String, state: PlaybackState) {
        #expect(ScriptingTerms.music.state(forEnumerator: code) == state)
    }

    @Test func spotifyKnowsThreeStates() {
        #expect(ScriptingTerms.spotify.state(forEnumerator: "kPSP") == .playing)
        #expect(ScriptingTerms.spotify.state(forEnumerator: "kPSp") == .paused)
        #expect(ScriptingTerms.spotify.state(forEnumerator: "kPSS") == .stopped)
    }

    @Test func codesTurnIntoNumbersAndBack() {
        #expect(FourCC.code("kPSP") == 0x6B50_5350)
        #expect(FourCC.code("hook") == 0x686F_6F6B)
        #expect(FourCC.text(0x6B50_5370) == "kPSp")
        for code in ["pPlS", "spfy", "PlPs", "ID  "] {
            #expect(FourCC.text(FourCC.code(code)) == code)
        }
        #expect(FourCC.code("toolong") == FourCC.code("tool"), "only four bytes count")
        #expect(!FourCC.isValid("abc"))
        #expect(!FourCC.isValid("abcde"))
        #expect(!FourCC.isValid("ab\u{1}c"))
    }

    @Test func eachPlayerIsFoundByItsOwnBundleID() {
        #expect(Player.music.bundleID == "com.apple.Music")
        #expect(Player.spotify.bundleID == "com.spotify.client")
        #expect(Player.music.permission == .automation(bundleID: "com.apple.Music"))
        #expect(Player.allCases.map(\.name) == ["Music", "Spotify"])
        #expect(Player.allCases.map(\.rawValue) == ["music", "spotify"], "stored in settings, never renamed")
    }
}
