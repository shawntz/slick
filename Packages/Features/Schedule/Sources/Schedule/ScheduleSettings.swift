import Foundation
import Kit

/// The feature's settings. `nonisolated`, so work off the main actor can read them.
nonisolated enum ScheduleSettings {
    /// IDs of calendars whose events stay out of My Schedule and meeting suggestions. Empty shows
    /// every calendar, so a calendar added later shows up without a trip to settings.
    static let hiddenCalendars = SettingKey("hiddenCalendars", default: [String]())
    /// Off by default: holidays and birthdays are part of a schedule for most people.
    static let hidesAllDayEvents = SettingKey("hidesAllDayEvents", default: false)
    /// On by default: a declined meeting is not one the user plans to attend.
    static let hidesDeclinedEvents = SettingKey("hidesDeclinedEvents", default: true)
    /// How far ahead My Schedule looks.
    static let range = SettingKey("range", default: ScheduleRange.week)
    /// Whether root search offers to join a meeting that is about to start.
    static let suggestsMeetings = SettingKey("suggestsMeetings", default: true)
    /// How long before a meeting starts the suggestion appears.
    static let leadTime = SettingKey("meetingLeadTime", default: MeetingLeadTime.tenMinutes)
    /// The list Create Reminder starts with. Empty uses the default list chosen in Reminders.
    static let defaultReminderList = SettingKey("defaultReminderList", default: "")

    /// What My Schedule depends on.
    static let scheduleKeys = [
        hiddenCalendars.erased, hidesAllDayEvents.erased, hidesDeclinedEvents.erased, range.erased,
    ]

    /// What the meeting suggestion depends on. It never offers a declined meeting, whatever
    /// My Schedule shows.
    static let suggestionKeys = [suggestsMeetings.erased, leadTime.erased, hiddenCalendars.erased]
}

/// How many days My Schedule shows, today included.
nonisolated enum ScheduleRange: String, SettingValue, CaseIterable, Sendable {
    case threeDays
    case week
    case twoWeeks
    case month

    var days: Int {
        switch self {
        case .threeDays: 3
        case .week: 7
        case .twoWeeks: 14
        case .month: 31
        }
    }
}

/// How long before a meeting the suggestion to join it appears.
nonisolated enum MeetingLeadTime: String, SettingValue, CaseIterable, Sendable {
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes

    var seconds: TimeInterval {
        switch self {
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .tenMinutes: 600
        case .fifteenMinutes: 900
        }
    }
}

/// What My Schedule and the suggestion read from settings, as one value work off the main thread
/// can carry.
nonisolated struct ScheduleOptions: Hashable, Sendable {
    var hiddenCalendars: Set<String> = []
    var hidesAllDayEvents = false
    var hidesDeclinedEvents = true
    var days = 7

    init(
        hiddenCalendars: Set<String> = [], hidesAllDayEvents: Bool = false, hidesDeclinedEvents: Bool = true,
        days: Int = 7
    ) {
        self.hiddenCalendars = hiddenCalendars
        self.hidesAllDayEvents = hidesAllDayEvents
        self.hidesDeclinedEvents = hidesDeclinedEvents
        self.days = days
    }

    init(_ settings: FeatureSettings) {
        self.init(
            hiddenCalendars: Set(settings[ScheduleSettings.hiddenCalendars]),
            hidesAllDayEvents: settings[ScheduleSettings.hidesAllDayEvents],
            hidesDeclinedEvents: settings[ScheduleSettings.hidesDeclinedEvents],
            days: settings[ScheduleSettings.range].days)
    }

    /// True when the event belongs in My Schedule under these options.
    func shows(_ event: EventOccurrence) -> Bool {
        if hiddenCalendars.contains(event.calendarID) { return false }
        if hidesAllDayEvents && event.isAllDay { return false }
        if hidesDeclinedEvents && event.attendance == .declined { return false }
        return true
    }
}
