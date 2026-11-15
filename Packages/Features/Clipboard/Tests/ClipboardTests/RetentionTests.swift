import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

@Suite("Retention and pruning", .timeLimit(.minutes(1)))
@MainActor
struct RetentionTests {
    @Test func itemsOlderThanTheRetentionPeriodGoButPinnedItemsStay() async throws {
        let clipboard = await ClipboardHarness()
        #expect(ClipboardSettings.retention.defaultValue == .threeMonths)
        clipboard.settings[ClipboardSettings.retention] = .week
        try await clipboard.harness.settle()
        try await clipboard.copy("old and pinned")
        try await clipboard.copy("old")
        try await clipboard.store.setPinned(true, key: ClipboardHarness.textKey("old and pinned"))
        clipboard.advance(minutes: 6 * 24 * 60)
        try await clipboard.copy("six days later")
        #expect(try await clipboard.store.count() == 3, "nothing is a week old yet")
        clipboard.advance(minutes: 2 * 24 * 60)
        try await clipboard.copy("new")
        #expect(
            try await clipboard.keys() == ["new", "six days later", "old and pinned"].map(ClipboardHarness.textKey))
    }

    @Test func shorteningTheRetentionPrunesAtOnce() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("two days old")
        clipboard.advance(minutes: 2 * 24 * 60)
        try await clipboard.copy("fresh")
        try await clipboard.openHistory()
        clipboard.settings[ClipboardSettings.retention] = .day
        try await clipboard.harness.settle()
        #expect(try await clipboard.store.count() == 1)
        #expect(clipboard.harness.rows.map(\.title) == ["fresh"], "the open page follows")
    }

    @Test func foreverKeepsEverything() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.retention] = .forever
        try await clipboard.copy("ancient")
        clipboard.advance(minutes: 3 * 365 * 24 * 60)
        try await clipboard.copy("today")
        #expect(try await clipboard.store.count() == 2)
    }

    @Test func theItemCapDropsTheOldestUnpinnedItems() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.maximumItems] = 3
        try await clipboard.copy("pinned")
        try await clipboard.store.setPinned(true, key: ClipboardHarness.textKey("pinned"))
        for text in ["one", "two", "three", "four"] {
            try await clipboard.copy(text)
        }
        #expect(try await clipboard.keys() == ["four", "three", "two", "pinned"].map(ClipboardHarness.textKey))
    }

    @Test func theImageStorageCapDropsTheOldestImages() async throws {
        let clipboard = await ClipboardHarness()
        clipboard.settings[ClipboardSettings.imageStorageMegabytes] = 1
        try await clipboard.copy([.image(Samples.fakeImage(bytes: 600_000, seed: 1), typeIdentifier: "public.png")])
        let first = try #require(try await clipboard.store.page(PageRequest()).items.first)
        try await clipboard.copy("text does not count")
        try await clipboard.copy([.image(Samples.fakeImage(bytes: 600_000, seed: 2), typeIdentifier: "public.png")])
        let page = try await clipboard.store.page(PageRequest())
        #expect(page.items.map(\.kind) == [.image, .text])
        #expect(page.items.first?.key != first.key)
        #expect(!FileManager.default.fileExists(atPath: try #require(first.imageURL).path))
    }

    @Test func activationPrunesWhatExpiredWhileTheAppWasClosed() async throws {
        let fakes = FakeServices()
        let start = fakes.clock.now
        let earlier = await ClipboardHarness(fakes: fakes, activate: false)
        try await earlier.store.record(
            TemporaryStore.capture("long ago"), at: start.addingTimeInterval(-200 * 24 * 3600))
        try await earlier.store.record(TemporaryStore.capture("recent"), at: start.addingTimeInterval(-3600))
        await earlier.harness.activate()
        await earlier.feature.startupPrune?.value
        #expect(try await earlier.keys() == [ClipboardHarness.textKey("recent")])
    }

    @Test func retentionCutoffsFollowTheCalendar() {
        let clock = FakeClock()
        let calendar = clock.calendar
        let now = clock.now
        #expect(Retention.day.cutoff(now: now, calendar: calendar) == now.addingTimeInterval(-86_400))
        #expect(Retention.week.cutoff(now: now, calendar: calendar) == now.addingTimeInterval(-7 * 86_400))
        #expect(
            Retention.threeMonths.cutoff(now: now, calendar: calendar)
                == calendar.date(byAdding: .month, value: -3, to: now))
        #expect(Retention.forever.cutoff(now: now, calendar: calendar) == nil)
    }
}
