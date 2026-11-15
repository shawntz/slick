import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

/// A feature with a web search that starts on, two fallbacks that start off, a command without
/// one, and Contacts in its manifest. It counts the grants it hears.
final class FinderFeature: Feature {
    static let manifest = FeatureManifest(
        id: "finder", name: "Finder", icon: .symbol("magnifyingglass"),
        permissions: [PermissionNeed(.contacts, reason: "Find people by name.")])

    static func id(_ command: String) -> ItemID { .command(feature: "finder", command: command) }

    private(set) var grants: [Permission] = []

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "web", title: "Search the Web", fallback: Fallback(startsOn: true) { "Web: \($0)" }) { _ in
                .close()
            },
            Command(id: "people", title: "Find People", fallback: Fallback { "People: \($0)" }) { _ in .close() },
            Command(id: "plain", title: "Plain Command") { _ in .close() },
            Command(id: "define", title: "Define", fallback: Fallback(title: { "Define: \($0)" })) { _ in .close() },
        ]
    }

    func permissionGranted(_ permission: Permission) async {
        grants.append(permission)
    }
}

@Suite("Fallback choices and grants", .timeLimit(.minutes(1)))
@MainActor struct FallbackAndGrantTests {
    @Test func aFallbackStartsOffUnlessItSaysOtherwise() {
        #expect(Fallback { $0 }.startsOn == false)
        #expect(Fallback(title: { $0 }).startsOn == false)
        #expect(Fallback(startsOn: true) { $0 }.startsOn)
    }

    @Test func choicesArrangeTheUsersOrderFirstAndKeepTheRestInPlace() {
        let a = FinderFeature.id("a")
        let b = FinderFeature.id("b")
        let c = FinderFeature.id("c")
        let gone = FinderFeature.id("gone")
        var choices = FallbackChoices()
        #expect(choices.isEmpty)
        #expect(choices.arranged([a, b, c]) == [a, b, c])
        choices.setOrder([c, gone, a, c])
        #expect(choices.order == [c, gone, a])
        #expect(choices.arranged([a, b, c]) == [c, a, b])
        #expect(choices.isOn(b, startsOn: true))
        choices.setOn(false, for: b)
        #expect(!choices.isOn(b, startsOn: true))
        choices.resetSwitch(for: b)
        #expect(choices.isOn(b, startsOn: true))
        #expect(!choices.isEmpty)
    }

    @Test func theDirectoryListsEveryFallbackWithItsSwitchInTheUsersOrder() throws {
        let fakes = FakeServices()
        let directory = FakeFeatureDirectory()
        let preferences = FakeItemPreferences(directory: directory)
        directory.register(FinderFeature.self, fakes: fakes)

        let initial = directory.fallbacks(preferences.fallbackChoices)
        #expect(initial.map(\.id) == [FinderFeature.id("web"), FinderFeature.id("people"), FinderFeature.id("define")])
        #expect(initial.map(\.isOn) == [true, false, false])

        let before = preferences.changes.generation
        preferences.setFallback(FinderFeature.id("people"), isOn: true)
        preferences.setFallbackOrder([FinderFeature.id("define"), FinderFeature.id("people")])
        #expect(preferences.changes.generation == before + 2)
        let chosen = directory.fallbacks(preferences.fallbackChoices)
        #expect(chosen.map(\.id) == [FinderFeature.id("define"), FinderFeature.id("people"), FinderFeature.id("web")])
        #expect(chosen.filter(\.isOn).map(\.id) == [FinderFeature.id("people"), FinderFeature.id("web")])

        directory.setEnabled(false, command: FinderFeature.id("people"))
        #expect(!directory.fallbacks(preferences.fallbackChoices).contains { $0.id == FinderFeature.id("people") })
        directory.setEnabled(false, feature: "finder")
        #expect(directory.fallbacks(preferences.fallbackChoices).isEmpty)
    }

    @Test func choicesRoundTripAsPlainStringsAndDropBadIDs() throws {
        var choices = FallbackChoices()
        choices.setOrder([FinderFeature.id("web"), FinderFeature.id("people")])
        choices.setOn(true, for: FinderFeature.id("people"))
        let data = try JSONEncoder().encode(choices)
        #expect(try JSONDecoder().decode(FallbackChoices.self, from: data) == choices)

        let edited = Data(
            #"{"order": ["cmd:finder.web", "no colon", "Bad:x"], "switches": {"cmd:finder.web": false, "??": true}}"#
                .utf8)
        let decoded = try JSONDecoder().decode(FallbackChoices.self, from: edited)
        #expect(decoded.order == [FinderFeature.id("web")])
        #expect(decoded.switches == [FinderFeature.id("web"): false])
        #expect(try JSONDecoder().decode(FallbackChoices.self, from: Data("{}".utf8)).isEmpty)
    }

    @Test func aGrantReachesOnlyFeaturesThatAreOnAndListThePermission() async {
        let fakes = FakeServices()
        let directory = FakeFeatureDirectory()
        let finder = directory.register(FinderFeature.self, fakes: fakes)
        let shelf = directory.register(ShelfFeature.self, fakes: fakes)

        await directory.permissionGranted(.contacts)
        await directory.permissionGranted(.calendars)
        #expect(finder.grants == [.contacts])
        #expect(shelf.activations == 0)
        #expect(directory.announcedGrants == [.contacts, .calendars])

        directory.setEnabled(false, feature: "finder")
        await directory.permissionGranted(.contacts)
        #expect(finder.grants == [.contacts])
    }

    @Test func aFeatureThatListsNoPermissionsStillValidates() {
        #expect(FeatureValidator.validate(FinderFeature(context: FakeServices().context(featureID: "finder"))).isEmpty)
    }
}
