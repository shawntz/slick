import Foundation
import Kit

/// The user's calendar and reminders in the launcher.
///
/// - My Schedule lists events by day from now on, with the time, calendar color, place and the
///   meeting link ``MeetingLinkFinder`` finds. Join Meeting comes first from 15 minutes before a
///   meeting with a link until it ends.
/// - A suggestion trigger offers to join a meeting with a link from shortly before it starts until
///   five minutes after.
/// - Create Event and Create Reminder read a typed phrase such as "Lunch tomorrow at 1pm" off the
///   main thread and open a form filled from it. Nothing is saved until the user submits.
/// - My Reminders lists what is overdue, due today, upcoming and undated, with Complete, Open in
///   Reminders and Delete, which asks first.
///
/// Everything goes through ``ScheduleStore``: EventKit in the app, memory everywhere else. Nothing
/// is read at launch. Each command asks the host for its permission only when the user runs it.
public final class ScheduleFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "schedule", name: Strings.featureName, icon: .symbol("calendar"), summary: Strings.featureSummary,
        permissions: [
            PermissionNeed(.calendars, reason: Strings.Reasons.calendars),
            PermissionNeed(.reminders, reason: Strings.Reasons.reminders),
        ])

    /// The command IDs, fixed: aliases, hotkeys and learning are keyed by them.
    enum CommandID {
        static let mySchedule = "my-schedule"
        static let createEvent = "create-event"
        static let myReminders = "my-reminders"
        static let createReminder = "create-reminder"
    }

    let context: FeatureContext
    let store: any ScheduleStore
    private let scheduleList: ScheduleList
    private let trigger: MeetingTrigger
    private var reminderList: ReminderList?

    /// Fires when the reminder lists settings offers change.
    public let declarationChanges: ChangeSignal? = ChangeSignal()

    /// The reminder lists seen since launch, for the default list picker in settings. Kept in memory
    /// only, and filled only after the user opened a reminders command, so settings never reads
    /// reminders by itself.
    private(set) var knownReminderLists: [CalendarInfo] = []

    /// Does no I/O. The live store touches nothing until a command runs.
    public init(context: FeatureContext) {
        self.context = context
        store = context.service(ScheduleStoreKey.self)
        scheduleList = ScheduleList(store: store, context: context)
        trigger = MeetingTrigger(store: store, settings: context.settings)
    }

    public var suggestionTriggers: [any SuggestionTrigger] { [trigger] }

    public var commands: [Command] {
        [mySchedule, createEvent, myReminders, createReminder]
    }

    // MARK: - Commands

    private var mySchedule: Command {
        Command(
            id: CommandID.mySchedule, title: Strings.Commands.mySchedule, icon: .symbol("calendar"),
            keywords: Strings.Commands.myScheduleKeywords, requires: [.calendars]
        ) { _ in
            guard await self.store.hasAccess(.events) else { return .needsPermission(.calendars) }
            let days = self.context.settings[ScheduleSettings.range].days
            return .push(
                .list(
                    ListPage(
                        self.scheduleList, title: Strings.Commands.mySchedule,
                        searchPlaceholder: Strings.Schedule.searchPlaceholder,
                        emptyState: ScheduleList.emptyState(days: days))))
        }
    }

    private var createEvent: Command {
        Command(
            id: CommandID.createEvent, title: Strings.Commands.createEvent, icon: .symbol("calendar.badge.plus"),
            keywords: Strings.Commands.createEventKeywords,
            arguments: [
                CommandArgument(Argument.event, placeholder: Strings.Commands.createEventPlaceholder, isOptional: true)
            ],
            requires: [.calendars], fallback: Fallback(title: Strings.Commands.createEventFallback)
        ) { context in
            let calendars: [CalendarInfo]
            do {
                guard await self.store.hasAccess(.events) else { return .needsPermission(.calendars) }
                calendars = try await self.store.calendars(.events)
            } catch ScheduleError.accessMissing(let permission) {
                return .needsPermission(permission)
            }
            guard calendars.contains(where: \.allowsModifications) else {
                throw ActionFailure(Strings.Forms.noWritableCalendar, message: Strings.Forms.noWritableCalendarMessage)
            }
            let typed = context.arguments[Argument.event] ?? ""
            let phrase = await NaturalLanguage.parse(typed, clock: FrozenClock(context.clock))
            return .push(
                .form(EventForm.page(phrase: phrase, calendars: calendars, clock: context.clock, store: self.store)))
        }
    }

    private var myReminders: Command {
        Command(
            id: CommandID.myReminders, title: Strings.Commands.myReminders, icon: .symbol("checklist"),
            keywords: Strings.Commands.myRemindersKeywords, requires: [.reminders]
        ) { _ in
            guard await self.store.hasAccess(.reminders) else { return .needsPermission(.reminders) }
            return .push(
                .list(
                    ListPage(
                        self.remindersSource, title: Strings.Commands.myReminders,
                        searchPlaceholder: Strings.Reminders.searchPlaceholder, filter: ReminderList.initialFilter,
                        emptyState: ReminderList.emptyState)))
        }
    }

    private var createReminder: Command {
        Command(
            id: CommandID.createReminder, title: Strings.Commands.createReminder, icon: .symbol("plus.circle"),
            keywords: Strings.Commands.createReminderKeywords,
            arguments: [
                CommandArgument(
                    Argument.reminder, placeholder: Strings.Commands.createReminderPlaceholder, isOptional: true)
            ],
            requires: [.reminders], fallback: Fallback(title: Strings.Commands.createReminderFallback)
        ) { context in
            let lists: [CalendarInfo]
            do {
                guard await self.store.hasAccess(.reminders) else { return .needsPermission(.reminders) }
                lists = try await self.store.calendars(.reminders)
            } catch ScheduleError.accessMissing(let permission) {
                return .needsPermission(permission)
            }
            self.saw(lists)
            guard lists.contains(where: \.allowsModifications) else {
                throw ActionFailure(Strings.Forms.noWritableList, message: Strings.Forms.noWritableListMessage)
            }
            let typed = context.arguments[Argument.reminder] ?? ""
            let phrase = await NaturalLanguage.parse(typed, clock: FrozenClock(context.clock))
            return .push(
                .form(
                    ReminderForm.page(
                        phrase: phrase, lists: lists,
                        preferredList: self.context.settings[ScheduleSettings.defaultReminderList],
                        clock: context.clock, store: self.store)))
        }
    }

    enum Argument {
        static let event = "event"
        static let reminder = "reminder"
    }

    /// Made on first use and kept, so the host sees one source.
    private var remindersSource: ReminderList {
        if let reminderList { return reminderList }
        let made = ReminderList(store: store, context: context) { [weak self] lists in self?.saw(lists) }
        reminderList = made
        return made
    }

    /// Remembers the reminder lists for the settings pane, and tells the host when they changed.
    func saw(_ lists: [CalendarInfo]) {
        let writable = lists.filter(\.allowsModifications)
        guard writable != knownReminderLists else { return }
        knownReminderLists = writable
        declarationChanges?.send()
    }

    // MARK: - Settings

    public var settingsPane: SettingsPane? {
        let store = store
        return SettingsPane([
            SettingsSection(
                Strings.Settings.scheduleSection,
                items: [
                    .multiSelect(
                        Strings.Settings.hiddenCalendars, key: ScheduleSettings.hiddenCalendars,
                        info: Strings.Settings.hiddenCalendarsInfo
                    ) {
                        await Self.calendarChoices(store)
                    },
                    .toggle(
                        Strings.Settings.hidesAllDay, key: ScheduleSettings.hidesAllDayEvents,
                        info: Strings.Settings.hidesAllDayInfo),
                    .toggle(
                        Strings.Settings.hidesDeclined, key: ScheduleSettings.hidesDeclinedEvents,
                        info: Strings.Settings.hidesDeclinedInfo),
                    .picker(
                        Strings.Settings.range, key: ScheduleSettings.range, info: Strings.Settings.rangeInfo,
                        titles: Strings.Settings.rangeTitle),
                ]),
            SettingsSection(
                Strings.Settings.suggestionSection,
                items: [
                    .toggle(
                        Strings.Settings.suggestsMeetings, key: ScheduleSettings.suggestsMeetings,
                        info: Strings.Settings.suggestsMeetingsInfo),
                    .picker(
                        Strings.Settings.leadTime, key: ScheduleSettings.leadTime, info: Strings.Settings.leadTimeInfo,
                        titles: Strings.Settings.leadTimeTitle),
                ]),
            SettingsSection(
                Strings.Settings.remindersSection,
                items: [
                    .picker(
                        Strings.Settings.defaultList, key: ScheduleSettings.defaultReminderList,
                        options: reminderListChoices, info: Strings.Settings.defaultListInfo)
                ]),
            SettingsSection(
                Strings.Settings.accessSection, footer: Strings.Settings.privacyNote,
                items: [
                    .permission(.calendars, info: Strings.Settings.calendarsInfo),
                    .permission(.reminders, info: Strings.Settings.remindersInfo),
                ]),
        ])
    }

    /// The default list picker's choices: Reminders' own default, the lists seen since launch, and
    /// the chosen list when it has not been seen yet.
    var reminderListChoices: [(value: String, title: String)] {
        var choices: [(value: String, title: String)] = [("", Strings.Settings.remindersDefaultList)]
        choices += EventForm.calendarOptions(knownReminderLists).map { ($0.value, $0.title) }
        let chosen = context.settings[ScheduleSettings.defaultReminderList]
        if !chosen.isEmpty, !choices.contains(where: { $0.value == chosen }) {
            choices.append((chosen, Strings.Settings.chosenListNotLoaded))
        }
        return choices
    }

    /// The calendars the hidden calendars setting offers. Read when the user opens the pane, and
    /// empty without access: the pane never asks for it.
    static func calendarChoices(_ store: any ScheduleStore) async -> [SettingsChoice] {
        guard let calendars = try? await store.calendars(.events) else { return [] }
        let options = EventForm.calendarOptions(calendars)
        return zip(calendars, options).map { calendar, option in
            SettingsChoice(
                id: calendar.id, title: option.title, icon: .symbol("circle.fill", tint: calendar.color ?? .gray))
        }
    }
}
