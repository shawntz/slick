import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Synchronization
import Testing

@testable import Root

/// The learning inspector over the real engine, and first-run seeding.
@Suite struct InspectorTests {
    @Test func theSummaryCountsRunsItemsAndQueries() async throws {
        let fixture = await RootFixture.ready()
        let inspector = fixture.root.inspector
        #expect(await inspector.summary() == .empty)

        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Calendar", for: "cal")
        let summary = await inspector.summary()
        #expect(summary.eventCount == 3)
        #expect(summary.itemCount == 2)
        // Every prefix of a typed query has its own row: t, te, ter, term, c, ca, cal.
        #expect(summary.queryCount == 7)
        #expect(summary.firstEvent == fixture.clock.now)
        #expect(summary.bytesOnDisk == 0)

        let top = await inspector.topItems(limit: 5)
        #expect(top.map(\.title) == ["Terminal", "Calendar"])
        #expect(top.first?.useCount == 2)
        #expect(await inspector.topItems(limit: 1).count == 1)
        await fixture.shutdown()
    }

    @Test func learnedQueriesListTheirItemsStrongestFirst() async throws {
        let fixture = await RootFixture.ready()
        let inspector = fixture.root.inspector
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Term", for: "term")

        let term = try #require(await inspector.queries(matching: "TERM", limit: 10).first)
        #expect(term.query == "term")
        #expect(term.items.map(\.title) == ["Terminal", "Term"])
        #expect(term.items[0].weight > 1.1)
        #expect(term.items[0].weight > term.items[1].weight)
        let all = await inspector.queries(matching: "", limit: 100)
        #expect(all.count == 4)
        #expect(await inspector.queries(matching: "zz", limit: 10).isEmpty)
        await fixture.shutdown()
    }

    @Test func forgettingAnItemOrAQueryRanksByTextAgain() async throws {
        let fixture = await RootFixture.ready()
        let inspector = fixture.root.inspector
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Editor", for: "ed")
        try await fixture.pick("Editor", for: "ed")
        #expect(fixture.results("term").first == "Terminal")
        #expect(fixture.results("e").first == "Editor")

        let changes = inspector.changes.generation
        await inspector.forget(query: "TERM")
        #expect(fixture.results("term").first == "Term")
        #expect(inspector.changes.generation > changes)
        #expect(await inspector.queries(matching: "term", limit: 5).isEmpty)

        await inspector.forget(item: fixture.apps.id("Editor"))
        await fixture.settle()
        #expect(fixture.results("ed").first == "Editor")
        #expect(fixture.root.usage.useCount(of: fixture.apps.id("Editor")) == 0)
        #expect(await inspector.topItems(limit: 5).map(\.title) == ["Terminal"])
        await fixture.shutdown()
    }

    @Test func pauseIsTheSharedSettingAndRecordsNothing() async throws {
        let fixture = await RootFixture.ready()
        let inspector = fixture.root.inspector
        let changes = inspector.changes.generation
        inspector.setPaused(true)
        #expect(inspector.isPaused)
        #expect(fixture.general[HostSettings.learningPaused])
        #expect(inspector.changes.generation > changes)
        await fixture.settle()
        try await fixture.pick("Terminal", for: "term")
        #expect(await inspector.summary().eventCount == 0)
        inspector.setPaused(false)
        await fixture.settle()
        try await fixture.pick("Terminal", for: "term")
        #expect(await inspector.summary().eventCount == 1)
        await fixture.shutdown()
    }

    @Test func eraseClearsTheEngineUsageRememberedRowsAndTriggerLearning() async throws {
        let folder = TemporaryFolder()
        let now = FakeClock().now
        let fixture = await RootFixture.ready(
            storage: RootStoragePaths(directory: folder.url), environment: .live, signals: true,
            offered: { $0.meetings.offered = [MeetingTrigger.meeting("standup", at: now)] })
        let inspector = fixture.root.inspector
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Terminal", for: "term")
        try await fixture.pick("Groceries List", for: "note groceries")
        _ = fixture.root.begin()
        fixture.clock.advance(by: .seconds(2))
        fixture.root.end()
        await fixture.settle()
        #expect(!fixture.root.learning.state.triggers.isEmpty)
        await fixture.root.flush()
        #expect(await inspector.summary().bytesOnDisk > 0)

        try await inspector.eraseAll()
        await fixture.settle()
        let summary = await inspector.summary()
        #expect(summary.eventCount == 0)
        #expect(summary.itemCount == 0)
        #expect(summary.queryCount == 0)
        #expect(summary.firstEvent == nil)
        #expect(fixture.results("term").first == "Term")
        #expect(fixture.results("groceries").isEmpty)
        #expect(fixture.root.learning.state.triggers.isEmpty)
        #expect(fixture.root.learning.state.ignored.isEmpty)
        #expect(fixture.root.usage.recentlyUsed(namespace: "app", limit: 5).isEmpty)
        await fixture.shutdown()
    }
}

@Suite struct SeedingTests {
    /// Counts how often App's seed provider was called.
    final class SeedCalls: Sendable {
        let count = Mutex(0)
    }

    @Test func theFirstRunTakesLightPriorsOnceAndNeverAgain() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let calls = SeedCalls()
        let now = FakeClock().now
        let apps = ExampleApps()
        let preview = apps.id("Preview")
        let music = apps.id("Music")
        let seeds: @Sendable () async -> [LearningSeed] = {
            calls.count.withLock { $0 += 1 }
            return [
                .dockApp(preview, now: now), .runningApp(preview, now: now),
                .countedApp(music, useCount: 40, lastUsed: now),
            ]
        }
        let first = await RootFixture.ready(storage: storage, environment: .live, apps: apps, seeds: seeds)
        await first.settle()
        #expect(calls.count.withLock { $0 } == 1)
        let suggested = first.root.begin().rows.map(\.title)
        first.root.end()
        #expect(suggested.contains("Preview") && suggested.contains("Music"))
        #expect(first.root.learning.state.seeded)
        // Seeds never teach a query: the exact title still wins.
        #expect(first.results("term").first == "Term")
        await first.root.flush()
        await first.shutdown()

        let second = await RootFixture.ready(storage: storage, environment: .live, apps: apps, seeds: seeds)
        await second.settle()
        #expect(calls.count.withLock { $0 } == 1)
        await second.shutdown()
    }

    @Test func historyFromBeforeMeansNoSeeding() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let first = await RootFixture.ready(storage: storage, environment: .live)
        try await first.pick("Terminal", for: "term")
        await first.root.flush()
        await first.shutdown()
        // learning.json was never written with a seed flag; the engine has history.
        try? FileManager.default.removeItem(at: folder.url.appending(path: "learning.json"))

        let calls = SeedCalls()
        let second = await RootFixture.ready(
            storage: storage, environment: .live,
            seeds: {
                calls.count.withLock { $0 += 1 }
                return []
            })
        await second.settle()
        #expect(calls.count.withLock { $0 } == 0)
        #expect(second.root.learning.state.seeded)
        await second.shutdown()
    }

    @Test func seedsAreMergedCappedAndLight() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = ItemID("app", "com.example.a")
        let b = ItemID("app", "com.example.b")
        #expect(abs(LearningSeed.countedApp(a, useCount: 40, lastUsed: now).weight - 0.15 * log(41)) < 1e-12)
        #expect(LearningSeed.dockApp(a, now: now).lastUsed == now.addingTimeInterval(-86_400))
        let merged = LearningSeed.merged([
            .dockApp(a, now: now), .runningApp(a, now: now), .countedApp(a, useCount: 1_000_000, lastUsed: now),
            LearningSeed(id: b, weight: -1, lastUsed: now), LearningSeed(id: b, weight: .nan, lastUsed: now),
            .recentDocument(b, lastUsed: now),
        ])
        #expect(merged.map(\.id) == [a, b])
        #expect(merged[0].weight == LearningSeed.maximumWeight)
        #expect(merged[0].lastUsed == now)
        #expect(merged[1].weight == 0.15)
    }
}
