import Foundation
import Kit
import Testing

@testable import SlickApp

@Suite("Deep link parsing")
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
