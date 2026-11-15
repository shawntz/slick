import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// Suggestions before typing, proven over the real engine with a fake clock and a fake system
/// context: habits that depend on the hour and on the app in front lead the empty state in their
/// own context and not in another.
@Suite(.timeLimit(.minutes(1))) struct PredictionTests {
    static let titles = ["Mail", "Calendar", "Terminal", "Editor", "Music", "Notes", "Preview"]
    /// Monday 16 November 2026, 00:00 UTC, the fake clock's time zone.
    static let monday = Date(timeIntervalSince1970: 1_794_787_200)

    private func fixture() async -> RootFixture {
        await RootFixture.ready(apps: ExampleApps(titles: Self.titles))
    }

    private func bundleID(_ title: String) -> String {
        "com.example." + title.lowercased()
    }

    /// Moves the clock forward to a day and time, as the Mac lives through it, and puts an app in
    /// front. A new morning starts a session, as a wake or an unlock does. Root search follows on
    /// its own: the hourly tick, the session start and the context change each refresh its context.
    private func live(
        _ fixture: RootFixture, day: Int, hour: Int, minute: Int = 0, front: String, wakes: Bool = false
    ) async {
        let target = Self.monday.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3_600 + minute * 60))
        let seconds = target.timeIntervalSince(fixture.clock.now)
        #expect(seconds > 0, "time only moves forward")
        fixture.clock.advance(by: .seconds(seconds))
        if wakes { fixture.system.simulateSessionStart(at: target) }
        fixture.system.simulateChange { $0.frontmostBundleID = bundleID(front) }
        await fixture.settle()
    }

    /// The Suggested rows the panel would show if summoned now, by title.
    private func suggested(_ fixture: RootFixture) -> [String] {
        let snapshot = fixture.root.begin()
        fixture.root.end()
        return snapshot.sections.first { $0.kind == .suggested }?.rows.map(\.title) ?? []
    }

    /// Opens the app the way people do: a summon, a few letters, Return on the app.
    private func open(_ fixture: RootFixture, _ title: String) async throws {
        try await fixture.pick(title, for: String(title.lowercased().prefix(3)))
    }

    @Test func aMorningHabitLeadsTheEmptyStateThatMorningAndNotThatAfternoon() async throws {
        let fixture = await fixture()
        // Four weekdays: Calendar each morning with Mail in front, Music at noon with Preview in
        // front, Terminal each afternoon with Editor in front. Terminal is always the latest run.
        for day in 0..<4 {
            await live(fixture, day: day, hour: 9, front: "Mail", wakes: true)
            try await open(fixture, "Calendar")
            await live(fixture, day: day, hour: 12, front: "Preview")
            try await open(fixture, "Music")
            await live(fixture, day: day, hour: 15, front: "Editor")
            try await open(fixture, "Terminal")
        }

        // Friday morning, Mail in front: Calendar first, though Terminal and Music ran later.
        await live(fixture, day: 4, hour: 9, front: "Mail", wakes: true)
        let morning = suggested(fixture)
        #expect(morning.first == "Calendar")
        #expect(!morning.contains("Mail"))

        // Friday afternoon, Editor in front: Terminal first, and Calendar is not.
        await live(fixture, day: 4, hour: 15, front: "Editor")
        let afternoon = suggested(fixture)
        #expect(afternoon.first == "Terminal")
        #expect(afternoon.first != "Calendar")
        #expect(!afternoon.contains("Editor"))
        await fixture.shutdown()
    }

    @Test func theAppInFrontAloneTellsTwoHabitsAtTheSameHourApart() async throws {
        let fixture = await fixture()
        // Each morning at the same hour: Calendar with Mail in front, then Terminal with Notes in
        // front half an hour later. The hour cannot tell them apart; the app in front can.
        for day in 0..<5 {
            await live(fixture, day: day, hour: 9, front: "Mail", wakes: true)
            try await open(fixture, "Calendar")
            await live(fixture, day: day, hour: 9, minute: 30, front: "Notes")
            try await open(fixture, "Terminal")
        }

        await live(fixture, day: 7, hour: 9, front: "Mail", wakes: true)
        #expect(suggested(fixture).first == "Calendar")
        await live(fixture, day: 7, hour: 9, minute: 10, front: "Notes")
        #expect(suggested(fixture).first == "Terminal")
        await fixture.shutdown()
    }

    @Test func theEmptyStateIsPreparedBeforeTheSummonAndFollowsTheContext() async throws {
        let fixture = await fixture()
        for day in 0..<4 {
            await live(fixture, day: day, hour: 9, front: "Mail", wakes: true)
            try await open(fixture, "Calendar")
            await live(fixture, day: day, hour: 15, front: "Editor")
            try await open(fixture, "Terminal")
        }
        await live(fixture, day: 4, hour: 9, front: "Mail", wakes: true)
        let prepared = fixture.root.preparedEmpty.rows.first?.title
        #expect(prepared == "Calendar")
        // The summon hands over what was prepared and computes nothing.
        let revision = fixture.root.snapshot.revision
        let summoned = fixture.root.begin()
        #expect(summoned.rows.first?.title == prepared)
        #expect(summoned.revision == revision + 1)
        fixture.root.end()

        // With the panel open on the empty state, the context changes: the rows follow at once.
        _ = fixture.root.begin()
        fixture.system.simulateChange { $0.frontmostBundleID = bundleID("Editor") }
        fixture.clock.advance(by: .seconds(6 * 3_600))
        await fixture.settle()
        #expect(fixture.root.snapshot.rows.first?.title == "Terminal")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func oneStrayRunDoesNotTakeOverAHabitsContext() async throws {
        let fixture = await fixture()
        for day in 0..<5 {
            await live(fixture, day: day, hour: 9, front: "Mail", wakes: true)
            try await open(fixture, "Calendar")
            await live(fixture, day: day, hour: 15, front: "Editor")
            try await open(fixture, "Terminal")
        }
        // One Monday morning the user opens Preview once, at the habit's hour with Mail in front.
        await live(fixture, day: 7, hour: 9, front: "Mail", wakes: true)
        try await open(fixture, "Preview")
        // The next morning in the same context the habit leads again.
        await live(fixture, day: 8, hour: 9, front: "Mail", wakes: true)
        #expect(suggested(fixture).first == "Calendar")
        await fixture.shutdown()
    }
}
