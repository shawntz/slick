import Foundation
import Kit
import KitTesting
import Testing

@Suite("Day sections")
struct DaySectionsTests {
    /// Saturday 14 November 2026, 09:30 UTC.
    private let clock = FakeClock()
    private let day: TimeInterval = 86_400

    @Test func historyLooksBack() {
        let sections = DaySections(clock: clock, direction: .past)
        let now = clock.now
        #expect(sections.title(for: now) == "Today")
        #expect(sections.title(for: now - day) == "Yesterday")
        #expect(sections.title(for: now - 2 * day) == "Thursday")
        #expect(sections.title(for: now - 9 * day) == "Thursday, November 5")
    }

    @Test func aScheduleLooksAhead() {
        let sections = DaySections(clock: clock, direction: .future)
        let now = clock.now
        #expect(sections.title(for: now + day) == "Tomorrow")
        #expect(sections.title(for: now + 2 * day) == "Monday")
        #expect(sections.title(for: now - day) == "Today", "an event that began earlier is listed today")
    }

    @Test func groupsSortedItemsWithStableIDs() {
        let now = clock.now
        let dates = [now, now - 3600, now - day]
        let sections = DaySections(clock: clock, direction: .past).sections(
            dates, date: { $0 }, row: { Row(id: ItemID("t", "\($0.timeIntervalSince1970)"), title: "x") })
        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(sections.map(\.id) == ["2026-11-14", "2026-11-13"])
        #expect(sections.map(\.rows.count) == [2, 1])
    }
}
