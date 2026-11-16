import Foundation
import Kit
import Testing

@testable import SlickApp

@Suite("Deep link parsing", .timeLimit(.minutes(1)))
struct DeepLinkTests {
    /// A link in the app's scheme.
    static func link(_ rest: String) -> String {
        Brand.urlScheme + "://" + rest
    }

    @Test func opensTheLauncher() throws {
        #expect(try DeepLink.parse(Self.link("")) == .open(query: nil))
        #expect(try DeepLink.parse(Self.link("open")) == .open(query: nil))
        #expect(try DeepLink.parse(Self.link("search")) == .open(query: nil))
        #expect(try DeepLink.parse(Self.link("search?q=")) == .open(query: nil))
    }

    @Test func readsTheSearchText() throws {
        #expect(try DeepLink.parse(Self.link("search?q=text%20editor")) == .open(query: "text editor"))
        #expect(try DeepLink.parse(Self.link("search?q=text+editor")) == .open(query: "text editor"))
        #expect(try DeepLink.parse(Self.link("search?q=1%2B1")) == .open(query: "1+1"))
        #expect(try DeepLink.parse(Self.link("search?q=caf%C3%A9")) == .open(query: "café"))
        #expect(try DeepLink.parse(Self.link("search?q=%20%20padded%20")) == .open(query: "padded"))
        #expect(try DeepLink.parse(Self.link("SEARCH?q=x")) == .open(query: "x"))
        // Three spaces in a row are fine, and padding at either end is dropped, not refused.
        #expect(try DeepLink.parse(Self.link("search?q=a%20%20%20b")) == .open(query: "a   b"))
        #expect(try DeepLink.parse(Self.link("search?q=x" + String(repeating: "%20", count: 40))) == .open(query: "x"))
    }

    @Test func acceptsTheSchemeInAnyCase() throws {
        #expect(try DeepLink.parse(Brand.urlScheme.uppercased() + "://search?q=x") == .open(query: "x"))
    }

    @Test func readsACommandAndItsArguments() throws {
        #expect(
            try DeepLink.parse(Self.link("commands/apps/running"))
                == .command(featureID: "apps", commandID: "running", arguments: [:]))
        #expect(
            try DeepLink.parse(Self.link("commands/web-search/search.v2?query=swift%20testing&engine=default"))
                == .command(
                    featureID: "web-search", commandID: "search.v2",
                    arguments: ["query": "swift testing", "engine": "default"]))
    }

    @Test func readsSettings() throws {
        #expect(try DeepLink.parse(Self.link("settings")) == .settings(pane: nil))
        #expect(try DeepLink.parse(Self.link("settings/")) == .settings(pane: nil))
        #expect(try DeepLink.parse(Self.link("settings/rootSearch")) == .settings(pane: "rootSearch"))
        #expect(try DeepLink.parse(Self.link("settings/features/apps")) == .featureSettings(featureID: "apps"))
    }

    /// Links a hostile page could fire, each with the refusal it must get.
    static let hostile: [(String, DeepLinkError)] = [
        ("javascript://search?q=x", .wrongScheme),
        ("file:///etc/hosts", .wrongScheme),
        ("https://example.com/search?q=x", .wrongScheme),
        (link("search?q=x").replacingOccurrences(of: "://", with: ":"), .malformed),
        (link("user:secret@search?q=x"), .hasCredentials),
        (link("search:8080?q=x"), .hasPort),
        (link("search?q=x#fragment"), .hasFragment),
        (link("search?q=%00"), .forbiddenCharacter),
        (link("search?q=line%0Abreak"), .forbiddenCharacter),
        (link("search?q=tab%09"), .forbiddenCharacter),
        (link("search?q=%E2%80%AEevil"), .forbiddenCharacter),
        (link("search?q=%E2%81%A6isolate"), .forbiddenCharacter),
        // Invisible format characters: zero-width space, word joiner, Arabic letter mark, a tag
        // character and the soft hyphen.
        (link("search?q=zero%E2%80%8Bwidth"), .forbiddenCharacter),
        (link("search?q=word%E2%81%A0joiner"), .forbiddenCharacter),
        (link("search?q=%D8%9Cmark"), .forbiddenCharacter),
        (link("search?q=tag%F3%A0%81%81"), .forbiddenCharacter),
        (link("search?q=soft%C2%ADhyphen"), .forbiddenCharacter),
        (link("commands/apps/running?q=notes%E2%80%8B"), .forbiddenCharacter),
        // Padding that pushes the rest of a value out of sight.
        (link("search?q=a%20%20%20%20b"), .tooManySpaces),
        (link("search?q=a++++b"), .tooManySpaces),
        (link("search?q=a%C2%A0%C2%A0%20%E3%80%80b"), .tooManySpaces),
        (link("commands/apps/running?q=notes" + String(repeating: "%20", count: 300) + "payload"), .tooManySpaces),
        (link("search?q=%zz"), .malformed),
        (link("search?q=100%"), .malformed),
        (link("search?q=%2"), .malformed),
        (link("search?q=a&q=b"), .duplicateItem("q")),
        (link("search?q"), .badItem("q")),
        (link("search?x=1"), .unexpectedItem("x")),
        (link("search?q=" + String(repeating: "a", count: 600)), .tooLong),
        (link("search?q=" + String(repeating: "a", count: 3000)), .tooLong),
        (link("search/extra"), .badPath),
        (link("delete-everything"), .unknownRoute),
        (link("commands/apps"), .badPath),
        (link("commands/apps/running/extra"), .badPath),
        (link("commands/../running"), .badPath),
        (link("commands/apps/.."), .badPath),
        (link("commands/apps/%2E%2E"), .badPath),
        (link("commands/apps%2Frunning/x"), .badPath),
        (link("commands//running"), .badPath),
        (link("commands/Apps/running"), .badFeatureID),
        (link("commands/app.s/running"), .badFeatureID),
        (link("commands/1apps/running"), .badFeatureID),
        (link("commands/apps%00/running"), .badFeatureID),
        (link("commands/apps/Running"), .badCommandID),
        (link("commands/apps/run..ning"), .badCommandID),
        (link("commands/apps/.running"), .badCommandID),
        (link("commands/apps/run%20ning"), .badCommandID),
        (link("commands/apps/running?a=1&b=2&c=3&d=4"), .tooManyArguments),
        (link("commands/apps/running?bad%20name=1"), .badItem("bad name")),
        (link("commands/apps/running?q=%00"), .forbiddenCharacter),
        (link("settings/../general"), .badPath),
        (link("settings/general?x=1"), .unexpectedItem("x")),
        (link("settings/general/more"), .badPath),
        (link("settings/gen-eral"), .badPath),
        (link("settings/features/Bad"), .badFeatureID),
        (link("settings/features/apps/more"), .badPath),
    ]

    @Test func refusesHostileLinks() {
        for (text, expected) in Self.hostile {
            #expect(throws: expected, "\(text)") { try DeepLink.parse(text) }
        }
    }

    @Test func refusesRawControlCharactersAndOverlongText() {
        #expect(throws: DeepLinkError.forbiddenCharacter) { try DeepLink.parse(Self.link("search?q=a\u{0}b")) }
        #expect(throws: DeepLinkError.tooLong) {
            try DeepLink.parse(Self.link(String(repeating: "x", count: DeepLink.maximumLength)))
        }
        #expect(throws: (any Error).self) { try DeepLink.parse("") }
        #expect(throws: (any Error).self) { try DeepLink.parse("not a url at all") }
    }

    /// Found in the second review: blank characters that are neither spaces nor format characters,
    /// such as the braille blank and the Hangul filler, padded an argument past what the page that
    /// asks shows at a glance. Emoji keep their presentation selector.
    @Test func refusesBlankCharactersThatAreNotSpaces() throws {
        let blanks = [
            "%E2%A0%80",  // U+2800 BRAILLE PATTERN BLANK
            "%E3%85%A4",  // U+3164 HANGUL FILLER
            "%EF%BE%A0",  // U+FFA0 HALFWIDTH HANGUL FILLER
            "%E1%85%9F",  // U+115F HANGUL CHOSEONG FILLER
            "%CD%8F",  // U+034F COMBINING GRAPHEME JOINER
            "%E1%A0%8B",  // U+180B MONGOLIAN FREE VARIATION SELECTOR ONE
            "%F3%A0%84%80",  // U+E0100 VARIATION SELECTOR-17
        ]
        for blank in blanks {
            #expect(throws: DeepLinkError.forbiddenCharacter, "\(blank)") {
                try DeepLink.parse(Self.link("commands/dictionary/define?word=notes" + blank + "payload"))
            }
        }
        let heart = try DeepLink.parse(Self.link("search?q=%E2%9D%A4%EF%B8%8F"))
        #expect(heart == .open(query: "\u{2764}\u{FE0F}"))
        let text = try DeepLink.parse(Self.link("search?q=%E2%98%BA%EF%B8%8E"))
        #expect(text == .open(query: "\u{263A}\u{FE0E}"))
    }

    @Test func countsEveryKindOfSpaceInARun() {
        #expect(DeepLink.longestSpaceRun("") == 0)
        #expect(DeepLink.longestSpaceRun("a b  c") == 2)
        #expect(DeepLink.longestSpaceRun("a\u{A0} \u{3000}b") == 3)
        #expect(DeepLink.longestSpaceRun("a\u{200B}\u{200B}b") == 0, "a format character is refused, not counted")
    }

    @Test func checksIDsTheWayKitDoes() {
        #expect(DeepLink.isFeatureID("apps"))
        #expect(DeepLink.isFeatureID("web-search2"))
        #expect(!DeepLink.isFeatureID(""))
        #expect(!DeepLink.isFeatureID(String(repeating: "a", count: 41)))
        #expect(DeepLink.isCommandID("quit-all"))
        #expect(!DeepLink.isCommandID("a/b"))
        #expect(DeepLink.isArgumentName("query_2"))
        #expect(!DeepLink.isArgumentName("q;rm"))
    }
}
