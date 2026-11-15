import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

@Suite struct EmptyStateTests {
    @Test func suggestedThenFavoritesEachFollowTheirSetting() async throws {
        let fixture = await RootFixture.ready()
        let apps = fixture.apps
        #expect(fixture.root.begin().sections.isEmpty)
        fixture.root.end()
        try await fixture.pick("Terminal", for: "terminal")
        try await fixture.pick("Calendar", for: "calendar")
        try await fixture.pick("Editor", for: "editor")

        let suggested = fixture.root.begin()
        fixture.root.end()
        #expect(suggested.sections.map(\.kind) == [.suggested])
        let titles = Set(suggested.rows.map(\.title))
        #expect(titles.isSuperset(of: ["Terminal", "Calendar"]))
        // The editor is the frontmost app in the fake context, and is never suggested.
        #expect(!titles.contains("Editor"))

        fixture.preferences.setFavorites([apps.id("Preview"), apps.id("Terminal")])
        await fixture.settle()
        let both = fixture.root.begin()
        fixture.root.end()
        #expect(both.sections.map(\.kind) == [.suggested, .favorites])
        #expect(both.sections.last?.rows.map(\.title) == ["Preview", "Terminal"])
        #expect(both.sections.first?.rows.contains { $0.title == "Terminal" } == false)

        fixture.general[HostSettings.showSuggestions] = false
        await fixture.settle()
        #expect(fixture.root.begin().sections.map(\.kind) == [.favorites])
        fixture.root.end()

        fixture.general[HostSettings.showFavorites] = false
        await fixture.settle()
        #expect(fixture.root.begin().sections.isEmpty)
        fixture.root.end()

        fixture.general[HostSettings.showSuggestions] = true
        fixture.general[HostSettings.suggestionCount] = 1
        await fixture.settle()
        #expect(fixture.root.begin().rows.count == 1)
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aContextChangeRecomputesSuggestionsWithoutTheNewFrontmostApp() async throws {
        let fixture = await RootFixture.ready()
        try await fixture.pick("Terminal", for: "terminal")
        try await fixture.pick("Calendar", for: "calendar")
        #expect(fixture.root.begin().rows.contains { $0.title == "Terminal" })
        fixture.root.end()

        fixture.system.simulateChange { $0.frontmostBundleID = "com.example.terminal" }
        await fixture.settle()
        let suggested = fixture.root.begin()
        fixture.root.end()
        #expect(!suggested.rows.contains { $0.title == "Terminal" })
        #expect(suggested.rows.contains { $0.title == "Calendar" })
        await fixture.shutdown()
    }

    @Test func beginHandsOverThePreparedSnapshotAndResetsTheSession() async throws {
        let fixture = await RootFixture.ready()
        fixture.preferences.setFavorites([fixture.apps.id("Music")])
        await fixture.settle()
        _ = fixture.root.update(query: "mus")
        let first = fixture.root.begin()
        #expect(first.query.isEmpty)
        #expect(first.rows.map(\.title) == ["Music"])
        #expect(fixture.root.snapshot.revision == first.revision)
        let second = fixture.root.begin()
        #expect(second.revision > first.revision)
        #expect(second.rows.map(\.id) == first.rows.map(\.id))
        await fixture.shutdown()
    }

    @Test func aFavoriteChangeDuringAnEmptySessionSignals() async throws {
        let fixture = await RootFixture.ready()
        _ = fixture.root.begin()
        let before = fixture.root.changes.generation
        fixture.preferences.setFavorites([fixture.apps.id("Music")])
        await fixture.settle()
        #expect(fixture.root.changes.generation > before)
        #expect(fixture.root.snapshot.rows.map(\.title) == ["Music"])
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func theContextUsesMondayAsDayZeroAndTheFrontmostAppKey() {
        let saturday = Date(timeIntervalSince1970: 1_794_648_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let system = SystemContext(frontmostBundleID: "com.example.editor", onBattery: true, displayCount: 2)
        let context = ContextBuilder.make(
            system: system, now: saturday, calendar: calendar,
            lastRun: ContextBuilder.LastRun(key: 7, at: saturday.addingTimeInterval(-90)), sessionStart: true)
        #expect(context.weekday == 5)
        #expect(context.hour == 9)
        #expect(context.frontmost?.rawValue == ItemID("app", "com.example.editor").engineKey)
        #expect(context.previous?.rawValue == 7)
        #expect(context.sincePrevious == 90)
        #expect(context.onBattery && context.sessionStart && context.displayCount == 2)
        #expect(ContextBuilder.untilNextHour(after: saturday, calendar: calendar) == .seconds(1_800))
    }
}
