import Foundation
import Kit

/// The Create Event form: title, start, length and calendar, filled from a typed phrase.
enum EventForm {
    enum Field {
        static let title = "title"
        static let start = "start"
        static let length = "length"
        static let calendar = "calendar"
    }

    /// The length option that makes an all-day event.
    static let allDay = "all-day"
    /// The lengths offered, in minutes.
    static let minutes = [15, 30, 45, 60, 90, 120, 180]
    static let defaultMinutes = 60

    static func page(
        phrase: ParsedPhrase, calendars: [CalendarInfo], clock: any ClockService, store: any ScheduleStore
    ) -> FormPage {
        let writable = calendars.filter(\.allowsModifications)
        let options = calendarOptions(writable)
        let initialCalendar = (writable.first(where: \.isDefault) ?? writable.first)?.id
        let start = phrase.date ?? nextSlot(after: clock.now, calendar: clock.calendar)
        return FormPage(
            title: Strings.Forms.createEventTitle,
            fields: [
                .text(
                    Field.title, title: Strings.Forms.title, placeholder: Strings.Forms.eventTitlePlaceholder,
                    initial: phrase.title, isRequired: true),
                .date(Field.start, title: Strings.Forms.starts, initial: start, includesTime: true),
                .dropdown(
                    Field.length, title: Strings.Forms.length, options: lengthOptions(including: phrase),
                    initial: initialLength(phrase)),
                .dropdown(
                    Field.calendar, title: Strings.Forms.calendar, options: options, initial: initialCalendar,
                    isRequired: true),
            ],
            submitTitle: Strings.Forms.createEventSubmit,
            requires: [.calendars],
            validate: { values in
                var errors: [String: FieldError] = [:]
                // A title of zero-width characters passes the required check but shows nothing.
                if OneLine.clean(values.text(Field.title)).isEmpty {
                    errors[Field.title] = FieldError(Strings.Forms.needsTitle)
                }
                if values.date(Field.start) == nil { errors[Field.start] = FieldError(Strings.Forms.needsStart) }
                if !writable.contains(where: { $0.id == values.text(Field.calendar) }) {
                    errors[Field.calendar] = FieldError(Strings.Forms.needsCalendar)
                }
                return errors
            },
            submit: { values, context in
                guard let draft = draft(from: values, calendar: context.clock.calendar) else {
                    throw ActionFailure(Strings.Forms.needsStart)
                }
                do {
                    _ = try await store.createEvent(draft)
                } catch ScheduleError.accessMissing(let permission) {
                    return .needsPermission(permission)
                }
                return .close(hud: .success(Strings.Forms.eventCreated))
            })
    }

    /// The event the form's values describe. An all-day event covers the start's whole day.
    static func draft(from values: FormValues, calendar: Calendar) -> EventDraft? {
        guard let start = values.date(Field.start) else { return nil }
        let title = OneLine.clean(values.text(Field.title), limit: 1_000)
        let calendarID = values.text(Field.calendar)
        if values.text(Field.length) == allDay {
            let day = calendar.startOfDay(for: start)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            return EventDraft(
                title: title, start: day, end: next.addingTimeInterval(-1), isAllDay: true,
                calendarID: calendarID.isEmpty ? nil : calendarID)
        }
        let minutes = Int(values.text(Field.length)) ?? defaultMinutes
        return EventDraft(
            title: title, start: start, end: start.addingTimeInterval(TimeInterval(max(1, minutes) * 60)),
            isAllDay: false, calendarID: calendarID.isEmpty ? nil : calendarID)
    }

    /// The next quarter of an hour after now, at least five minutes away: a sensible start for a new
    /// event when the phrase names none.
    static func nextSlot(after now: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second], from: now)
        let pastHour = (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        var slot = now.addingTimeInterval(TimeInterval(((pastHour / 900) + 1) * 900 - pastHour))
        if slot.timeIntervalSince(now) < 300 { slot.addTimeInterval(900) }
        return slot
    }

    static func lengthOptions(including phrase: ParsedPhrase) -> [CommandArgument.Option] {
        var choices = minutes
        if let duration = phrase.duration {
            let parsed = Int((duration / 60).rounded())
            if parsed > 0, !choices.contains(parsed) { choices = (choices + [parsed]).sorted() }
        }
        return choices.map { CommandArgument.Option(Strings.Forms.minutes($0), value: String($0)) }
            + [CommandArgument.Option(Strings.Forms.allDay, value: allDay)]
    }

    static func initialLength(_ phrase: ParsedPhrase) -> String {
        if phrase.isDateOnly && phrase.date != nil { return allDay }
        if let duration = phrase.duration, duration >= 60 { return String(Int((duration / 60).rounded())) }
        return String(defaultMinutes)
    }

    /// Calendars by title. Two calendars with the same title get their account after it.
    static func calendarOptions(_ calendars: [CalendarInfo]) -> [CommandArgument.Option] {
        let titles = calendars.map { OneLine.clean($0.title, limit: 60) }
        return zip(calendars, titles).map { calendar, title in
            let repeated = titles.filter { $0 == title }.count > 1 && !calendar.account.isEmpty
            let shown =
                repeated ? Strings.Forms.calendarInAccount(title, OneLine.clean(calendar.account, limit: 40)) : title
            return CommandArgument.Option(shown, value: calendar.id)
        }
    }
}

/// The Create Reminder form: title, due date, list and priority, filled from a typed phrase.
enum ReminderForm {
    enum Field {
        static let title = "title"
        static let due = "due"
        static let dateOnly = "date-only"
        static let list = "list"
        static let priority = "priority"
    }

    static func page(
        phrase: ParsedPhrase, lists: [CalendarInfo], preferredList: String, clock: any ClockService,
        store: any ScheduleStore
    ) -> FormPage {
        let writable = lists.filter(\.allowsModifications)
        let initialList =
            (writable.first { $0.id == preferredList } ?? writable.first(where: \.isDefault) ?? writable.first)?.id
        return FormPage(
            title: Strings.Forms.createReminderTitle,
            fields: [
                .text(
                    Field.title, title: Strings.Forms.title, placeholder: Strings.Forms.reminderTitlePlaceholder,
                    initial: phrase.title, isRequired: true),
                .date(Field.due, title: Strings.Forms.due, initial: phrase.date, includesTime: true),
                .checkbox(
                    Field.dateOnly, title: Strings.Forms.time, label: Strings.Forms.dateOnlyLabel,
                    initial: phrase.isDateOnly),
                .dropdown(
                    Field.list, title: Strings.Forms.list, options: EventForm.calendarOptions(writable),
                    initial: initialList, isRequired: true),
                .dropdown(
                    Field.priority, title: Strings.Forms.priorityLabel, options: priorityOptions,
                    initial: String(ReminderPriority.none.rawValue)),
            ],
            submitTitle: Strings.Forms.createReminderSubmit,
            requires: [.reminders],
            validate: { values in
                var errors: [String: FieldError] = [:]
                if OneLine.clean(values.text(Field.title)).isEmpty {
                    errors[Field.title] = FieldError(Strings.Forms.needsTitle)
                }
                if !writable.contains(where: { $0.id == values.text(Field.list) }) {
                    errors[Field.list] = FieldError(Strings.Forms.needsList)
                }
                return errors
            },
            submit: { values, context in
                let draft = draft(from: values, timeZone: context.clock.timeZone, calendar: context.clock.calendar)
                do {
                    _ = try await store.createReminder(draft)
                } catch ScheduleError.accessMissing(let permission) {
                    return .needsPermission(permission)
                }
                return .close(hud: .success(Strings.Forms.reminderCreated))
            })
    }

    static let priorityOptions = [ReminderPriority.none, .low, .medium, .high].map {
        CommandArgument.Option(Strings.Forms.priorityName($0), value: String($0.rawValue))
    }

    /// The reminder the form's values describe. A reminder due on a day keeps only the day.
    static func draft(from values: FormValues, timeZone: TimeZone, calendar: Calendar) -> ReminderDraft {
        let dateOnly = values.bool(Field.dateOnly)
        let due = values.date(Field.due).map { dateOnly ? calendar.startOfDay(for: $0) : $0 }
        let list = values.text(Field.list)
        return ReminderDraft(
            title: OneLine.clean(values.text(Field.title), limit: 1_000), due: due, dueHasTime: due != nil && !dateOnly,
            priority: Int(values.text(Field.priority)).flatMap(ReminderPriority.init(rawValue:)) ?? .none,
            listID: list.isEmpty ? nil : list, timeZone: timeZone)
    }
}
