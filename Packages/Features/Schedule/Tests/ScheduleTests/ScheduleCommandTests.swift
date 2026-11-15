import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@MainActor
@Suite("My Schedule command and actions", .timeLimit(.minutes(1)))
struct ScheduleCommandTests {
    typealias F = Fixture

    static func review(startingIn minutes: Int, link: String? = Fixture.meetLink) -> EventOccurrence {
        F.event(
            "review", "Design Review", start: F.start.addingTimeInterval(TimeInterval(minutes * 60)),
            location: "Room 4", notes: link.map { "Join: \($0)" })
    }

    @Test func nothingIsReadAtLaunchAndTheListOpensWhenRun() async throws {
        let store = F.store(events: [Self.review(startingIn: 90), F.event("p", "Planning", start: F.date(day: 15, 9))])
        let harness = F.harness(store)
        #expect(harness.issues.isEmpty)
        await harness.activate()
        #expect(store.eventQueries.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)

        try await harness.run("my-schedule")
        #expect(harness.sections.map(\.title) == ["Today", "Tomorrow"])
        #expect(harness.rows.map(\.title) == ["Design Review", "Planning"])
        #expect(store.eventQueries == [F.start...F.date(day: 21, 0)])
        _ = harness.actions()
        #expect(harness.issues.isEmpty)
        await harness.deactivate()
        #expect(harness.fakes.permissions.openStreamCount == 0)
    }

    @Test func calendarsAreAskedForOnlyWhenTheUserRunsTheCommand() async throws {
        let store = F.store(events: [Self.review(startingIn: 5)])
        let harness = F.harness(store, fakes: FakeServices(permissions: .notDetermined))
        await harness.activate()
        #expect(try await harness.suggestions().isEmpty)
        await #expect(throws: HarnessError.permissionRequired([.calendars])) { try await harness.run("my-schedule") }
        #expect(harness.fakes.permissions.requests.isEmpty, "nothing prompts before the user presses Grant")
        #expect(store.eventQueries.isEmpty)

        harness.grantsMissingPermissions = true
        try await harness.run("my-schedule")
        #expect(harness.fakes.permissions.requests == [.calendars])
        #expect(harness.rows.map(\.title) == ["Design Review"])
    }

    @Test func aStoreWithoutAccessReturnsNeedsPermission() async throws {
        let store = F.store(events: [Self.review(startingIn: 5)])
        store.setAccess(.events, granted: false)
        let harness = F.harness(store)
        await #expect(throws: HarnessError.permissionRequired([.calendars])) { try await harness.run("my-schedule") }
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.pages.isEmpty)

        store.setAccess(.events, granted: true)
        try await harness.run("my-schedule")
        #expect(harness.rows.count == 1)
    }

    @Test func accessLostWhileTheListIsOpenOffersToGrantIt() async throws {
        let store = F.store(events: [Self.review(startingIn: 30)])
        let harness = F.harness(store)
        try await harness.run("my-schedule")
        store.setAccess(.events, granted: false)
        harness.fakes.permissions.set(.calendars, to: .denied)
        try await harness.reloadPage()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Access to Calendars")
        #expect(harness.actions().map(\.id) == ["grant-access"])
        #expect(harness.actions().first?.requires == [.calendars])

        store.setAccess(.events, granted: true)
        harness.grantsMissingPermissions = true
        try await harness.perform("grant-access")
        #expect(harness.fakes.permissions.requests == [.calendars])
        #expect(harness.rows.map(\.title) == ["Design Review"])
        #expect(harness.issues.isEmpty)
    }

    @Test func joinMeetingComesFirstFromFifteenMinutesBeforeUntilTheEnd() async throws {
        let store = F.store(events: [Self.review(startingIn: 20)])
        let harness = F.harness(store)
        try await harness.run("my-schedule")
        #expect(harness.actions().map(\.id) == ["open-in-calendar", "join", "copy-details", "copy-link"])
        #expect(harness.actions().secondary?.id == "join", "Command-Return joins")

        harness.fakes.clock.advance(by: .seconds(5 * 60))  // 15 minutes before
        #expect(harness.actions().map(\.id) == ["join", "open-in-calendar", "copy-details", "copy-link"])
        harness.fakes.clock.advance(by: .seconds(15 * 60 + 29 * 60))  // one minute before the end
        #expect(harness.actions().first?.id == "join")
        harness.fakes.clock.advance(by: .seconds(60))  // ended
        #expect(harness.actions().first?.id == "open-in-calendar")

        harness.fakes.clock.set(F.start.addingTimeInterval(10 * 60))
        try await harness.performPrimary()
        #expect(harness.fakes.workspace.opened == [URL(string: F.meetLink)])
        #expect(harness.isClosed)
        #expect(harness.issues.isEmpty)
    }

    @Test func anEventWithoutALinkOffersNoJoin() async throws {
        let harness = F.harness(F.store(events: [Self.review(startingIn: 5, link: nil)]))
        try await harness.run("my-schedule")
        #expect(harness.actions().map(\.id) == ["open-in-calendar", "copy-details"])
        #expect(harness.actions().secondary == nil)
    }

    @Test func openInCalendarShowsTheEventOrOpensCalendar() async throws {
        let harness = F.harness(F.store(events: [Self.review(startingIn: 60)]))
        try await harness.run("my-schedule")
        try await harness.perform("open-in-calendar")
        #expect(
            harness.fakes.workspace.opened == [URL(string: "ical://ekevent/external-review?method=show&options=more")])
        #expect(harness.isClosed)

        harness.fakes.workspace.failsToOpen = true
        try await harness.perform("open-in-calendar")
        #expect(harness.fakes.workspace.launched == ["com.apple.iCal"])
    }

    @Test func copyDetailsAndCopyMeetingLink() async throws {
        let harness = F.harness(F.store(events: [Self.review(startingIn: 90)]))
        try await harness.run("my-schedule")
        try await harness.perform("copy-details")
        #expect(
            harness.fakes.pasteboard.copiedTexts.map(plain) == [
                "Design Review\nSaturday, November 14, 11:00 AM \u{2013} 11:30 AM\nRoom 4\n\(F.meetLink)"
            ])
        #expect(harness.huds == ["Copied Details"])
        try await harness.perform("copy-link")
        #expect(harness.fakes.pasteboard.copiedTexts.last == F.meetLink)
        #expect(harness.huds.last == "Copied Meeting Link")
        #expect(try #require(harness.actions().first { $0.id == "copy-link" }).shortcut == .copy)
    }

    @Test func copyDetailsDescribesAllDayAndLongEvents() {
        let text = TimeText(clock: F.clock(F.start))
        let allDay = EventSummary(
            F.event("a", "Holiday", start: F.date(day: 16, 0), allDay: true, end: F.date(day: 17, 0)), link: nil)
        #expect(EventActions.details(allDay, text: text) == "Holiday\nMonday, November 16, all day")
        let trip = EventSummary(
            F.event("t", "Trip", start: F.date(day: 16, 0), allDay: true, end: F.date(day: 19, 0)), link: nil)
        #expect(EventActions.when(trip, text: text) == "Monday, November 16 to Wednesday, November 18")
        let overnight = EventSummary(
            F.event("o", "Overnight", start: F.date(day: 16, 22), end: F.date(day: 17, 6)), link: nil)
        #expect(
            plain(EventActions.when(overnight, text: text))
                == "Monday, November 16, 10:00 PM to Tuesday, November 17, 6:00 AM")
    }

    @Test func theListFollowsTheStoreAndTheSettings() async throws {
        let store = F.store(events: [
            Self.review(startingIn: 30),
            F.event("bday", "Birthday", start: F.date(day: 15, 0), allDay: true, end: F.date(day: 16, 0)),
        ])
        let harness = F.harness(store)
        try await harness.run("my-schedule")
        #expect(harness.rows.map(\.title) == ["Design Review", "Birthday"])

        store.add(F.event("new", "New meeting", start: F.date(day: 14, 16)))
        try await harness.settle()
        #expect(harness.rows.map(\.title) == ["Design Review", "New meeting", "Birthday"])

        harness.context.settings[ScheduleSettings.hidesAllDayEvents] = true
        try await harness.settle()
        #expect(harness.rows.map(\.title) == ["Design Review", "New meeting"])

        harness.context.settings[ScheduleSettings.hiddenCalendars] = [F.work.id]
        try await harness.settle()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Upcoming Events")
        #expect(harness.actions().map(\.id) == ["run.cmd:schedule.create-event"])

        harness.context.settings[ScheduleSettings.range] = .threeDays
        harness.context.settings.reset(ScheduleSettings.hiddenCalendars)
        try await harness.settle()
        #expect(store.eventQueries.last == F.start...F.date(day: 17, 0))
    }

    @Test func typingFiltersByTitleCalendarPlaceAndService() async throws {
        let harness = F.harness(
            F.store(events: [
                Self.review(startingIn: 30), F.event("h", "Groceries", start: F.date(day: 14, 17), calendar: F.home),
            ]))
        try await harness.run("my-schedule")
        try await harness.setQuery("google meet")
        #expect(harness.rows.map(\.title) == ["Design Review"])
        try await harness.setQuery("home")
        #expect(harness.rows.map(\.title) == ["Groceries"])
        try await harness.setQuery("room 4")
        #expect(harness.rows.map(\.title) == ["Design Review"])
    }

    @Test func actionsWorkFromARowRebuiltFromASnapshot() async throws {
        let harness = F.harness(F.store(events: [Self.review(startingIn: 5)]))
        try await harness.run("my-schedule")
        let row = try #require(harness.selectedRow)
        let rebuilt = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        guard case .list(let page) = harness.page?.page else {
            Issue.record("not a list")
            return
        }
        let actions = page.source.actions(for: rebuilt)
        #expect(actions.map(\.id) == ["join", "open-in-calendar", "copy-details", "copy-link"])
        try await harness.perform(try #require(actions.first), row: rebuilt)
        #expect(harness.fakes.workspace.opened == [URL(string: F.meetLink)])
        // A row from another feature, or with a broken payload, has no actions.
        #expect(page.source.actions(for: Row(id: ItemID("schedule.event", "x"), title: "x")).isEmpty)
    }

    @Test func theIsolatedStoreShowsSampleDataAndTouchesNothing() async throws {
        for environment in [RunEnvironment.scenario, .selftest, .bench] {
            let context = FakeServices().context(featureID: "schedule", environment: environment)
            #expect(context.service(ScheduleStoreKey.self) is MemoryScheduleStore)
        }
        let harness = FeatureHarness(ScheduleFeature.self, environment: .scenario)
        #expect(harness.feature.store is MemoryScheduleStore)
        try await harness.run("my-schedule")
        #expect(harness.rows.first?.title == "Design Review")
        #expect(harness.actions().first?.id == "join")
        #expect(try await harness.suggestions().map(\.row.title) == ["Join Design Review"])
        try await harness.run("my-reminders")
        #expect(harness.sections.map(\.title) == ["Overdue", "Today", "Upcoming", "No Due Date"])
        #expect(harness.issues.isEmpty)
    }
}
