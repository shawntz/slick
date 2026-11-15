import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

@Suite struct UsageServiceTests {
    @Test func usesOrderByRecencyAndFrecencyHalvesEveryWeek() async throws {
        let fixture = await RootFixture.ready()
        let usage = fixture.root.usage
        let first = ItemID("emoji", "a")
        let second = ItemID("emoji", "b")
        usage.recordUse(of: first)
        fixture.clock.advance(by: .seconds(60))
        usage.recordUse(of: second)
        fixture.clock.advance(by: .seconds(60))
        usage.recordUse(of: Row(id: first, title: "First"))

        #expect(usage.recentlyUsed(namespace: "emoji", limit: 5).map(\.id) == [first, second])
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 1).first?.snapshot?.title == "First")
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 0).isEmpty)
        #expect(usage.useCount(of: first) == 2)
        let now = try #require(usage.frecency(namespace: "emoji")[second])
        #expect(abs(now - 1) < 0.001)

        fixture.clock.advance(by: .seconds(7 * 86_400))
        let week = try #require(usage.frecency(namespace: "emoji")[second])
        #expect(abs(week - 0.5) < 0.001)
        #expect(usage.frecency(namespace: "other").isEmpty)

        usage.forget(second)
        #expect(usage.useCount(of: second) == 0)
        usage.forgetAll(namespace: "emoji")
        #expect(usage.recentlyUsed(namespace: "emoji", limit: 5).isEmpty)
        await fixture.shutdown()
    }

    @Test func usesAreSavedAndLoaded() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        do {
            let first = await RootFixture.ready(storage: storage)
            first.root.usage.recordUse(of: ItemID("emoji", "a"))
            first.root.usage.recordUse(of: ItemID("emoji", "a"))
            await first.root.flush()
            await first.shutdown()
        }
        let second = await RootFixture.ready(storage: storage)
        #expect(second.root.usage.useCount(of: ItemID("emoji", "a")) == 2)
        await second.shutdown()
    }
}

@Suite struct FuzzyIndexServiceTests {
    @Test func tiersOrderAndHighlightsFollowTheEngine() async throws {
        let service = EngineFuzzyIndexService()
        let index = await service.makeIndex([
            FuzzyEntry(title: "Calculator"), FuzzyEntry(title: "Calendar"),
            FuzzyEntry(title: "Notes", keywords: ["memo"]),
            FuzzyEntry(title: "Cal"),
        ])
        #expect(index.count == 4)

        let cal = index.search("cal", limit: 10)
        #expect(cal.map(\.index).prefix(3) == [3, 1, 0])
        #expect(cal.first?.tier == .exact)
        #expect(cal.dropFirst().first?.tier == .prefix)
        #expect(cal.dropFirst().first?.highlights == [0..<3])
        #expect(cal[0].score > cal[1].score)

        let typo = try #require(index.search("calender", limit: 5).first)
        #expect(typo.index == 1)
        #expect(typo.tier == .typo)
        #expect(index.search("memo", limit: 5).map(\.index) == [2])
        #expect(index.search("cal", limit: 1).count == 1)
        #expect(index.search("", limit: 5).isEmpty)
        #expect(index.search("cal", limit: 0).isEmpty)
    }

    @Test func aLimitAboveTheBufferGrowsIt() async {
        let entries = (0..<200).map { FuzzyEntry(title: "Item \($0)") }
        let index = await EngineFuzzyIndexService().makeIndex(entries)
        #expect(index.search("item", limit: 150).count == 150)
    }

    /// Host asks for every match with `Int.max`. That once sized the buffer and trapped.
    @Test func anUnboundedLimitReturnsEveryMatch() async {
        let entries = (0..<70).map { FuzzyEntry(title: "Item \($0)") }
        let index = await EngineFuzzyIndexService().makeIndex(entries)
        #expect(index.search("item", limit: .max).count == 70)
        #expect(index.search("zzz", limit: .max).isEmpty)
        let empty = await EngineFuzzyIndexService().makeIndex([])
        #expect(empty.search("item", limit: .max).isEmpty)
    }

    @Test func engineTiersMapToKitTiers() {
        #expect(EngineFuzzyIndex.tier(6) == .exact)
        #expect(EngineFuzzyIndex.tier(5) == .prefix)
        #expect(EngineFuzzyIndex.tier(1) == .typo)
        #expect(EngineFuzzyIndex.tier(0) == .subsequence)
        #expect(EngineFuzzyIndex.tier(9) == .exact)
    }
}
