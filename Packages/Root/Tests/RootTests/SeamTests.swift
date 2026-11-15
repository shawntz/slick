import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// What root search hands the other packages through KitHosting: the band holder and the
/// suggestion triggers in the learning inspector, and live subtitles with their color.
@Suite struct SeamTests {
    @Test func theBandHolderIsMarkedEvenWhenAnotherItemIsStronger() async throws {
        let fixture = await RootFixture.ready()
        let inspector = fixture.root.inspector
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        var term = try #require(await inspector.queries(matching: "term", limit: 10).first { $0.query == "term" })
        #expect(term.items.filter(\.holdsBand).map(\.title) == ["Terminal"])

        // Term is credited three times but never twice in a row, so Terminal keeps the band.
        try await fixture.pick("Term", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Term", for: "term")
        term = try #require(await inspector.queries(matching: "term", limit: 10).first { $0.query == "term" })
        #expect(term.items.map(\.title) == ["Term", "Terminal"], "strongest first")
        #expect(term.items.filter(\.holdsBand).map(\.title) == ["Terminal"])

        // A second credit in a row hands the band over.
        try await fixture.pick("Term", for: "term")
        term = try #require(await inspector.queries(matching: "term", limit: 10).first { $0.query == "term" })
        #expect(term.items.filter(\.holdsBand).map(\.title) == ["Term"])
        await fixture.shutdown()
    }

    @Test func theInspectorListsTriggersAndResetsOne() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let meetings = try fixture.signalsFeature().meetings
        let inspector: any LearningInspector = fixture.root.inspector
        let fresh = try #require(await inspector.triggers().first)
        #expect(fresh.id == "signals.meeting-soon")
        #expect(!fresh.isOff)
        #expect(fresh.acceptance == meetings.prior.mean)

        fixture.root.learning.update { state in
            var stats = TriggerStats(prior: meetings.prior, now: fixture.clock.now)
            stats.isOff = true
            stats.impressions = 25
            state.triggers["signals.meeting-soon"] = stats
        }
        #expect(await inspector.triggers().map(\.isOff) == [true])

        let generation = inspector.changes.generation
        let asks = meetings.asks.count
        await inspector.resetTrigger(featureID: "signals", triggerID: "meeting-soon")
        await fixture.settle()
        let reset = try #require(await inspector.triggers().first)
        #expect(!reset.isOff)
        #expect(reset.impressions == 0)
        #expect(inspector.changes.generation > generation)
        #expect(meetings.asks.count == asks + 1, "the trigger is asked again at once")
        await fixture.shutdown()
    }

    @Test func aLiveSubtitleCarriesItsColorAndFetchesOffTheMainThread() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let disk = try fixture.signalsFeature().disk
        disk.color = .red
        _ = fixture.root.begin()
        _ = fixture.root.update(query: "disk status")
        await fixture.settle()
        var row = try #require(fixture.root.snapshot.rows.first { $0.title == "Disk Status" })
        #expect(row.subtitle == "Disk ok 1")
        #expect(row.subtitleColor == .red)
        #expect(disk.fetches == 1)
        #expect(disk.fetchesOnMainThread == 0)

        disk.color = nil
        disk.signal.send()
        await fixture.settle()
        row = try #require(fixture.root.snapshot.rows.first { $0.title == "Disk Status" })
        #expect(row.subtitle == "Disk ok 2")
        #expect(row.subtitleColor == nil, "a value without a color goes back to the theme's")

        disk.color = .green
        disk.signal.send()
        await fixture.settle()
        let next = fixture.root.update(query: "disk stat")
        #expect(next.rows.first?.subtitleColor == .green, "the next keystroke keeps the color")
        #expect(disk.fetchesOnMainThread == 0)
        fixture.root.end()
        await fixture.shutdown()
    }
}
