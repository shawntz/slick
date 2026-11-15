import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

/// Cases a second review found: a calendar removed while its form is open, titles that show
/// nothing, an open list that went stale, and what the settings pane says is read.
@MainActor
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    typealias F = Fixture

    // MARK: - A calendar removed elsewhere

    @Test func anEventForACalendarRemovedSinceTheFormOpenedIsNotSavedElsewhere() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event", arguments: ["event": "Lunch tomorrow at 1pm"])
        try harness.fill("calendar", text: F.home.id)
        store.removeCalendar(id: F.home.id)
        await #expect(throws: ScheduleError.calendarGone) { try await harness.submit() }
        #expect(store.createdEvents.isEmpty, "never saved to the default calendar instead")
        #expect(store.allEvents.isEmpty)
    }

    @Test func aReminderForAListRemovedSinceTheFormOpenedIsNotSavedElsewhere() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-reminder", arguments: ["reminder": "Call the bank tomorrow at 10am"])
        try harness.fill("list", text: F.errands.id)
        store.removeCalendar(id: F.errands.id)
        await #expect(throws: ScheduleError.calendarGone) { try await harness.submit() }
        #expect(store.createdReminders.isEmpty)
        #expect(store.allReminders.isEmpty)
    }

    @Test func theFailureSaysNothingWasSaved() {
        let error = ScheduleError.calendarGone
        #expect(error.errorDescription == "Calendar Not Found")
        #expect(error.failureReason?.contains("nothing was saved") == true)
    }

    // MARK: - Titles that show nothing

    static let invisible = "\u{200B}\u{2060}\u{FEFF}"

    @Test func invisibleTitlesFallBackToUntitled() throws {
        let event = F.event(
            "zw", Self.invisible, start: F.date(day: 14, 9, 35), url: URL(string: F.meetLink))
        let sections = EventRows.build([event], options: ScheduleOptions(), clock: F.clock(F.start))
        let row = try #require(sections.first?.rows.first)
        #expect(row.title == "Untitled Event")
        let summary = try #require(row.summary)
        let details = EventActions.details(summary, text: TimeText(clock: F.clock(F.start)))
        #expect(details.hasPrefix("Untitled Event\n"))

        let suggestions = MeetingTrigger.build([event], at: F.start, lead: 600, options: ScheduleOptions())
        #expect(suggestions.map(\.row.title) == ["Join Untitled Event"])

        let reminder = F.reminder("zw", Self.invisible + " \u{200D}")
        let reminderRows = ReminderRows.build([reminder], listID: nil, clock: F.clock(F.start))
        #expect(reminderRows.first?.rows.first?.title == "Untitled Reminder")
        #expect(Strings.Reminders.deleteQuestion(ReminderSummary(reminder).title) == "Delete This Reminder?")
    }

    @Test func oneLineKeepsVisibleTextAndDropsInvisibleText() {
        #expect(OneLine.clean(Self.invisible).isEmpty)
        #expect(OneLine.clean(" \u{200B}\n\t ").isEmpty)
        #expect(OneLine.clean("\u{200B}Stand-up") == "\u{200B}Stand-up")
        #expect(OneLine.clean("Café 👩‍💻 sync") == "Café 👩‍💻 sync")
        #expect(OneLine.clean("\u{200F}שלום") == "\u{200F}שלום")
        #expect(OneLine.clean(String(repeating: "\u{200B}", count: 500), limit: 10).isEmpty)
    }

    @Test func aFormTitleThatShowsNothingIsRefused() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event")
        try harness.fill("title", text: Self.invisible)
        await #expect(throws: HarnessError.invalidForm(["title": FieldError(Strings.Forms.needsTitle)])) {
            try await harness.submit()
        }
        try await harness.run("create-reminder")
        try harness.fill("title", text: Self.invisible)
        await #expect(throws: HarnessError.invalidForm(["title": FieldError(Strings.Forms.needsTitle)])) {
            try await harness.submit()
        }
        #expect(store.createdEvents.isEmpty)
        #expect(store.createdReminders.isEmpty)
    }

    // MARK: - An open list that goes stale

    @Test func theListLoadsAgainWhenTheNextEventStartsOrEnds() async throws {
        // Now is 09:30. A meeting runs until 09:50, the next starts at 11:00.
        let store = F.store(events: [
            F.event("running", "Planning", start: F.date(day: 14, 9, 20)),
            F.event("next", "Review", start: F.date(day: 14, 11)),
        ])
        let harness = F.harness(store)
        try await harness.run("my-schedule")
        #expect(harness.page?.refreshAfter == .seconds(20 * 60))
        #expect(harness.rows.first?.accessories.contains(.tag(Strings.Schedule.now, color: .green)) == true)

        harness.fakes.clock.advance(by: .seconds(20 * 60))
        try await harness.refresh()
        #expect(harness.rows.map(\.title) == ["Review"], "the ended meeting leaves")
        #expect(harness.page?.refreshAfter == .seconds(70 * 60))

        harness.fakes.clock.advance(by: .seconds(70 * 60))
        try await harness.refresh()
        #expect(harness.rows.first?.accessories.contains(.tag(Strings.Schedule.now, color: .green)) == true)
    }

    @Test func anEmptyDayLoadsAgainAtMidnight() {
        let clock = F.clock(F.start)
        #expect(EventRows.refreshDelay([], options: ScheduleOptions(), clock: clock) == .seconds(14.5 * 3_600))
        let hidden = F.event("hidden", "Hidden", start: F.date(day: 14, 10), calendar: F.home)
        let options = ScheduleOptions(hiddenCalendars: [F.home.id])
        #expect(EventRows.refreshDelay([hidden], options: options, clock: clock) == .seconds(14.5 * 3_600))
        let soon = F.event("soon", "Soon", start: F.start.addingTimeInterval(0.2))
        #expect(EventRows.refreshDelay([soon], options: ScheduleOptions(), clock: clock) == .seconds(1))
    }

    @Test func theDayTurnsInTheUsersTimeZone() {
        // 09:30 UTC is 01:30 in Los Angeles, so the day turns in 22.5 hours there.
        let clock = F.clock(F.start, timeZone: "America/Los_Angeles")
        #expect(EventRows.refreshDelay([], options: ScheduleOptions(), clock: clock) == .seconds(22.5 * 3_600))
    }

    // MARK: - What the pane says

    @Test func thePrivacyNoteSaysRootSearchReadsCalendarsOnceAMinute() {
        let note = Strings.Settings.privacyNote
        #expect(note.contains("once a minute"))
        #expect(note.contains("nothing is sent over the network"))
    }
}
