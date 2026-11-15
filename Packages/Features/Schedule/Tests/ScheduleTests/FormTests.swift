import Foundation
import Kit
import KitTesting
import Testing

@testable import Schedule

@MainActor
@Suite("Create Event and Create Reminder", .timeLimit(.minutes(1)))
struct FormTests {
    typealias F = Fixture

    private func form(_ harness: FeatureHarness<ScheduleFeature>) throws -> FormPage {
        guard case .form(let form) = harness.page?.page else { throw HarnessError.wrongPage(expected: "form") }
        return form
    }

    private func options(_ form: FormPage, _ field: String) -> [String] {
        guard case .dropdown(let options, _) = form.fields.first(where: { $0.id == field })?.kind else { return [] }
        return options.map(\.value)
    }

    private func values(_ harness: FeatureHarness<ScheduleFeature>) -> FormValues {
        harness.page?.formValues ?? FormValues()
    }

    // MARK: - Create Event

    @Test func aTypedPhraseFillsTheEventForm() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event", arguments: ["event": "Lunch tomorrow at 1pm"])
        let form = try form(harness)
        #expect(form.title == "Create Event")
        #expect(form.requires == [.calendars])
        #expect(values(harness).text("title") == "Lunch")
        #expect(values(harness).date("start") == F.date(day: 15, 13))
        #expect(values(harness).text("length") == "60")
        #expect(values(harness).text("calendar") == F.work.id)
        #expect(options(form, "calendar") == [F.work.id, F.home.id], "read-only calendars are not offered")
        #expect(store.createdEvents.isEmpty, "nothing is saved before the user submits")

        let outcome = try await harness.submit()
        #expect(outcome.kind == .close(hud: .success("Event Created")))
        #expect(
            store.createdEvents == [
                EventDraft(
                    title: "Lunch", start: F.date(day: 15, 13), end: F.date(day: 15, 14), isAllDay: false,
                    calendarID: F.work.id)
            ])
        #expect(harness.issues.isEmpty)
    }

    @Test func withoutAPhraseTheFormStartsAtTheNextQuarterHourAndNeedsATitle() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event")
        #expect(values(harness).text("title") == "")
        #expect(values(harness).date("start") == F.date(day: 14, 9, 45))
        await #expect(throws: HarnessError.invalidForm(["title": "Required"])) { try await harness.submit() }
        try harness.fill("title", text: "Focus time")
        try harness.fill("length", text: "30")
        try harness.fill("calendar", text: F.home.id)
        try await harness.submit()
        #expect(
            store.createdEvents == [
                EventDraft(
                    title: "Focus time", start: F.date(day: 14, 9, 45), end: F.date(day: 14, 10, 15), isAllDay: false,
                    calendarID: F.home.id)
            ])
    }

    @Test func aDayWithNoTimeMakesAnAllDayEvent() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event", arguments: ["event": "Holiday tomorrow"])
        #expect(values(harness).text("title") == "Holiday")
        #expect(values(harness).text("length") == EventForm.allDay)
        try await harness.submit()
        let draft = try #require(store.createdEvents.first)
        #expect(draft.isAllDay)
        #expect(draft.start == F.date(day: 15, 0))
        #expect(draft.end == F.date(day: 16, 0).addingTimeInterval(-1))
    }

    @Test func aPhraseWithALengthChoosesIt() async throws {
        let harness = F.harness(F.store())
        try await harness.run("create-event", arguments: ["event": "Review today from 2pm to 3:30pm"])
        #expect(values(harness).text("title") == "Review")
        #expect(values(harness).date("start") == F.date(day: 14, 14))
        #expect(values(harness).text("length") == "90")

        try await harness.run("create-event", arguments: ["event": "Sync today from 2pm to 2:20pm"])
        #expect(values(harness).text("length") == "20")
        #expect(options(try form(harness), "length").prefix(2) == ["15", "20"], "an unusual length is offered")
    }

    @Test func aReadOnlyCalendarIsRefused() async throws {
        let harness = F.harness(F.store())
        try await harness.run("create-event", arguments: ["event": "Party tomorrow at 8pm"])
        try harness.fill("calendar", text: F.holidays.id)
        await #expect(throws: HarnessError.invalidForm(["calendar": FieldError(Strings.Forms.needsCalendar)])) {
            try await harness.submit()
        }
    }

    @Test func withNoWritableCalendarTheCommandSaysWhy() async throws {
        let store = MemoryScheduleStore(calendars: [F.holidays], lists: F.lists)
        let harness = F.harness(store)
        await #expect(
            throws: ActionFailure(Strings.Forms.noWritableCalendar, message: Strings.Forms.noWritableCalendarMessage)
        ) {
            try await harness.run("create-event")
        }
    }

    @Test func createEventIsOfferedAsAFallback() async throws {
        let harness = F.harness(F.store())
        let fallback = try #require(try harness.command("create-event").fallback)
        #expect(fallback.title("Dentist tomorrow at 9am") == "Create Event \u{201C}Dentist tomorrow at 9am\u{201D}")
        try await harness.runFallback("create-event", text: "Dentist tomorrow at 9am")
        #expect(values(harness).text("title") == "Dentist")
        #expect(values(harness).date("start") == F.date(day: 15, 9))
    }

    @Test func aRootLaunchIgnoresTheTextThatFoundTheCommand() async throws {
        let harness = F.harness(F.store())
        try await harness.run("create-event", query: "create ev", launch: .root)
        #expect(values(harness).text("title") == "")
    }

    @Test func accessLostBeforeSubmittingAsksAgain() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event", arguments: ["event": "Call tomorrow at 2pm"])
        store.setAccess(.events, granted: false)
        await #expect(throws: HarnessError.permissionRequired([.calendars])) { try await harness.submit() }
        #expect(store.createdEvents.isEmpty)
    }

    @Test func aSaveFailureSaysWhy() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-event", arguments: ["event": "Call tomorrow at 2pm"])
        store.setFailsWrites(true)
        harness.throwsActionErrors = false
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Could Not Save")
        #expect(harness.toasts.last?.message == Strings.Failure.saveFailedReason)
    }

    @Test func createEventAsksForCalendarsOnlyWhenRun() async throws {
        let harness = F.harness(F.store(), fakes: FakeServices(permissions: .notDetermined))
        await #expect(throws: HarnessError.permissionRequired([.calendars])) { try await harness.run("create-event") }
        #expect(harness.fakes.permissions.requests.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.run("create-event")
        #expect(harness.fakes.permissions.requests == [.calendars])
    }

    // MARK: - Create Reminder

    @Test func aTypedPhraseFillsTheReminderForm() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-reminder", arguments: ["reminder": "Call the bank tomorrow at 10am"])
        let form = try form(harness)
        #expect(form.requires == [.reminders])
        #expect(values(harness).text("title") == "Call the bank")
        #expect(values(harness).date("due") == F.date(day: 15, 10))
        #expect(values(harness).bool("date-only") == false)
        #expect(values(harness).text("list") == F.inbox.id)
        #expect(values(harness).text("priority") == "0")
        #expect(options(form, "list") == [F.inbox.id, F.errands.id], "read-only lists are not offered")

        try harness.fill("priority", text: "1")
        let outcome = try await harness.submit()
        #expect(outcome.kind == .close(hud: .success("Reminder Created")))
        #expect(
            store.createdReminders == [
                ReminderDraft(
                    title: "Call the bank", due: F.date(day: 15, 10), dueHasTime: true, priority: .high,
                    listID: F.inbox.id, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
            ])
        #expect(harness.issues.isEmpty)
    }

    @Test func aReminderWithNoDateHasNoDueDate() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-reminder", arguments: ["reminder": "Buy milk"])
        #expect(values(harness).text("title") == "Buy milk")
        #expect(values(harness).date("due") == nil)
        try await harness.submit()
        let draft = try #require(store.createdReminders.first)
        #expect(draft.due == nil)
        #expect(!draft.dueHasTime)
    }

    @Test func aDayWithNoTimeKeepsOnlyTheDay() async throws {
        let store = F.store()
        let harness = F.harness(store)
        try await harness.run("create-reminder", arguments: ["reminder": "Pay rent tomorrow"])
        #expect(values(harness).text("title") == "Pay rent")
        #expect(values(harness).bool("date-only"))
        try await harness.submit()
        let draft = try #require(store.createdReminders.first)
        #expect(draft.due == F.date(day: 15, 0))
        #expect(!draft.dueHasTime)

        // Unchecking the box keeps the time the user set.
        try await harness.run("create-reminder", arguments: ["reminder": "Pay rent tomorrow"])
        try harness.fill("due", .date(F.date(day: 15, 8, 30)))
        try harness.fill("date-only", .bool(false))
        try await harness.submit()
        #expect(store.createdReminders.last?.due == F.date(day: 15, 8, 30))
        #expect(store.createdReminders.last?.dueHasTime == true)
    }

    @Test func theDefaultListComesFromSettings() async throws {
        let harness = F.harness(F.store())
        harness.context.settings[ScheduleSettings.defaultReminderList] = F.errands.id
        try await harness.run("create-reminder")
        #expect(values(harness).text("list") == F.errands.id)

        harness.context.settings[ScheduleSettings.defaultReminderList] = F.archive.id
        try await harness.run("create-reminder")
        #expect(values(harness).text("list") == F.inbox.id, "a read-only list falls back to the default")

        harness.context.settings[ScheduleSettings.defaultReminderList] = "gone"
        try await harness.run("create-reminder")
        #expect(values(harness).text("list") == F.inbox.id)
    }

    @Test func createReminderIsOfferedAsAFallbackAndAsksForAccessOnlyWhenRun() async throws {
        let harness = F.harness(F.store(), fakes: FakeServices(permissions: .notDetermined))
        await #expect(throws: HarnessError.permissionRequired([.reminders])) {
            try await harness.runFallback("create-reminder", text: "Water the plants")
        }
        #expect(harness.fakes.permissions.requests.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.runFallback("create-reminder", text: "Water the plants")
        #expect(harness.fakes.permissions.requests == [.reminders])
        #expect(values(harness).text("title") == "Water the plants")
    }

    @Test func aStoreWithoutReminderAccessReturnsNeedsPermission() async throws {
        let store = F.store()
        store.setAccess(.reminders, granted: false)
        let harness = F.harness(store)
        await #expect(throws: HarnessError.permissionRequired([.reminders])) {
            try await harness.run("create-reminder")
        }
        #expect(harness.fakes.permissions.requests.isEmpty)
    }

    @Test func nextSlotRoundsUpToAQuarterHourAtLeastFiveMinutesAway() {
        let calendar = F.utc
        #expect(EventForm.nextSlot(after: F.date(day: 14, 9, 30), calendar: calendar) == F.date(day: 14, 9, 45))
        #expect(EventForm.nextSlot(after: F.date(day: 14, 9, 41), calendar: calendar) == F.date(day: 14, 10, 0))
        #expect(EventForm.nextSlot(after: F.date(day: 14, 9, 42), calendar: calendar) == F.date(day: 14, 10, 0))
        #expect(EventForm.nextSlot(after: F.date(day: 14, 9, 56), calendar: calendar) == F.date(day: 14, 10, 15))
        #expect(EventForm.nextSlot(after: F.date(day: 14, 23, 58), calendar: calendar) == F.date(day: 15, 0, 15))
    }
}
