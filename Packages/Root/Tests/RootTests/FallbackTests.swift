import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

/// A feature with three fallbacks: a web search that starts on, and two that start off.
final class LookupFeature: Feature {
    static let manifest = FeatureManifest(id: "lookup", name: "Lookup", icon: .symbol("magnifyingglass"))

    static let web = ItemID.command(feature: "lookup", command: "web")
    static let define = ItemID.command(feature: "lookup", command: "define")
    static let ask = ItemID.command(feature: "lookup", command: "ask")

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "web", title: "Search the Web", fallback: Fallback(startsOn: true) { "Web: \($0)" }) { _ in
                .close()
            },
            Command(id: "define", title: "Define Word", fallback: Fallback { "Define \($0)" }) { _ in .close() },
            Command(id: "ask", title: "Ask a Question", fallback: Fallback(title: { "Ask about \($0)" })) { _ in
                .close()
            },
        ]
    }
}

@Suite(.timeLimit(.minutes(1))) struct FallbackTests {
    /// The fallback rows for a query, by ID.
    private func shown(_ fixture: RootFixture, _ query: String) -> [ItemID] {
        fixture.root.update(query: query).sections.first { $0.kind == .fallbacks }?.rows.map(\.id) ?? []
    }

    private func lookupFixture() async -> RootFixture {
        let fixture = await RootFixture.ready()
        fixture.directory.register(LookupFeature.self, fakes: fixture.fakes)
        await fixture.settle()
        return fixture
    }

    @Test func onlyFallbacksThatStartOnShowUntilTheUserChooses() async throws {
        let fixture = await lookupFixture()
        _ = fixture.root.begin()
        let library = ItemID.command(feature: "library", command: "search")
        #expect(shown(fixture, "qwzx") == [library, LookupFeature.web])
        #expect(Fallback { $0 }.startsOn == false)
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func theUsersSwitchesAndOrderDecideWhatShows() async throws {
        let fixture = await lookupFixture()
        let library = ItemID.command(feature: "library", command: "search")
        fixture.preferences.setFallback(LookupFeature.define, isOn: true)
        fixture.preferences.setFallback(library, isOn: false)
        await fixture.settle()
        _ = fixture.root.begin()
        #expect(shown(fixture, "qwzx") == [LookupFeature.web, LookupFeature.define])

        fixture.preferences.setFallbackOrder([LookupFeature.define, LookupFeature.ask, LookupFeature.web, library])
        await fixture.settle()
        #expect(shown(fixture, "qwzx") == [LookupFeature.define, LookupFeature.web])

        // Settings reads the same list through the directory, so it shows what root search shows.
        let listed = fixture.directory.fallbacks(fixture.preferences.fallbackChoices)
        #expect(listed.map(\.id) == [LookupFeature.define, LookupFeature.ask, LookupFeature.web, library])
        #expect(listed.filter(\.isOn).map(\.id) == [LookupFeature.define, LookupFeature.web])
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func turningAFallbackOffTakesItOffTheScreenAtOnce() async throws {
        let fixture = await lookupFixture()
        _ = fixture.root.begin()
        #expect(shown(fixture, "qwzx").contains(LookupFeature.web))
        let before = fixture.root.changes.generation
        fixture.preferences.setFallback(LookupFeature.web, isOn: false)
        await fixture.settle()
        #expect(fixture.root.changes.generation > before)
        let rows = fixture.root.snapshot.sections.first { $0.kind == .fallbacks }?.rows.map(\.id) ?? []
        #expect(!rows.contains(LookupFeature.web))
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func theOlderSettingDecidesOnlyWhileTheUserHasNoChoices() async throws {
        let fixture = await lookupFixture()
        fixture.general[HostSettings.fallbackCommands] = [LookupFeature.ask.rawValue, LookupFeature.define.rawValue]
        await fixture.settle()
        _ = fixture.root.begin()
        #expect(shown(fixture, "qwzx") == [LookupFeature.ask, LookupFeature.define])

        fixture.preferences.setFallback(LookupFeature.ask, isOn: true)
        await fixture.settle()
        let library = ItemID.command(feature: "library", command: "search")
        #expect(shown(fixture, "qwzx") == [library, LookupFeature.web, LookupFeature.ask])
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aFallbackOfACommandOrFeatureThatIsOffNeverShows() async throws {
        let fixture = await lookupFixture()
        fixture.preferences.setFallback(LookupFeature.define, isOn: true)
        fixture.directory.setEnabled(false, command: LookupFeature.define)
        await fixture.settle()
        _ = fixture.root.begin()
        #expect(!shown(fixture, "qwzx").contains(LookupFeature.define))
        fixture.directory.setEnabled(false, feature: "lookup")
        await fixture.settle()
        #expect(!shown(fixture, "qwzx").contains(LookupFeature.web))
        fixture.root.end()
        await fixture.shutdown()
    }
}
