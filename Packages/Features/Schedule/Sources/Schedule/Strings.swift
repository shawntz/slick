import Foundation
import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Subtitles are short phrases. Messages and settings help are plain
/// sentences that say what will happen.
nonisolated enum Strings {
    static let featureName = "Calendar and Reminders"
    static let featureSummary =
        "See your schedule, join meetings, add events and keep up with your reminders from Calendar and Reminders."

    /// "9:30 AM – 10:00 AM".
    static func timeRange(_ start: String, _ end: String) -> String {
        "\(start) \u{2013} \(end)"
    }

    static func provider(_ provider: MeetingProvider) -> String {
        switch provider {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .faceTime: "FaceTime"
        case .slack: "Slack Huddle"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi Meet"
        case .goTo: "GoTo Meeting"
        case .blueJeans: "BlueJeans"
        case .chime: "Amazon Chime"
        case .skype: "Skype"
        case .ringCentral: "RingCentral"
        }
    }

    // MARK: - Permission reasons

    enum Reasons {
        static let calendars = "Show your upcoming events, find their meeting links and add the events you create."
        static let reminders = "Show your reminders, complete or delete the ones you choose and add new ones."
    }

    // MARK: - Commands

    enum Commands {
        static let mySchedule = "My Schedule"
        static let myScheduleKeywords = ["calendar", "events", "agenda", "meetings", "today", "upcoming", "join"]
        static let createEvent = "Create Event"
        static let createEventKeywords = ["new event", "add event", "calendar", "meeting", "schedule"]
        static let createEventPlaceholder = "Lunch tomorrow at 1pm"
        static let myReminders = "My Reminders"
        static let myRemindersKeywords = ["reminders", "todo", "to do", "tasks", "due", "overdue"]
        static let createReminder = "Create Reminder"
        static let createReminderKeywords = ["new reminder", "add reminder", "remind me", "todo", "task"]
        static let createReminderPlaceholder = "Call the bank tomorrow at 10am"

        @Sendable static func createEventFallback(_ text: String) -> String {
            "Create Event \u{201C}\(text)\u{201D}"
        }

        @Sendable static func createReminderFallback(_ text: String) -> String {
            "Create Reminder \u{201C}\(text)\u{201D}"
        }
    }

    // MARK: - My Schedule

    enum Schedule {
        static let searchPlaceholder = "Search events"
        static let untitled = "Untitled Event"
        static let allDay = "All day"
        static let continues = "Continues all day"
        static let now = "Now"
        static let declined = "Declined"
        static let canceled = "Canceled"
        static let invited = "Invited"
        static let emptyTitle = "No Upcoming Events"

        static func allDayOf(day: Int, of count: Int) -> String {
            "All day, day \(day) of \(count)"
        }

        static func starts(_ time: String) -> String {
            "Starts at \(time)"
        }

        static func ends(_ time: String) -> String {
            "Ends at \(time)"
        }

        static func emptyMessage(_ days: Int) -> String {
            days == 1
                ? "Nothing else is on your calendars today."
                : "Nothing is on your calendars for the next \(days) days."
        }
    }

    // MARK: - Event actions

    enum Actions {
        static let joinMeeting = "Join Meeting"
        static let openInCalendar = "Open in Calendar"
        static let copyDetails = "Copy Details"
        static let copiedDetails = "Copied Details"
        static let copyMeetingLink = "Copy Meeting Link"
        static let copiedMeetingLink = "Copied Meeting Link"
    }

    /// The when line of Copy Details.
    enum Details {
        static func allDay(_ day: String) -> String {
            "\(day), all day"
        }

        static func sameDay(_ day: String, _ range: String) -> String {
            "\(day), \(range)"
        }

        static func dayAndTime(_ day: String, _ time: String) -> String {
            "\(day), \(time)"
        }

        static func span(_ start: String, _ end: String) -> String {
            "\(start) to \(end)"
        }
    }

    // MARK: - Suggestion

    enum Suggestion {
        static func title(_ event: String) -> String {
            "Join \(event)"
        }

        static func subtitle(provider: String) -> String {
            "Opens the call in \(provider)"
        }
    }

    // MARK: - My Reminders

    enum Reminders {
        static let searchPlaceholder = "Search reminders"
        static let untitled = "Untitled Reminder"
        static let listFilter = "List"
        static let allLists = "All Lists"
        static let emptyTitle = "No Reminders"
        static let emptyMessage = "Nothing is left to do. Reminders you add here or in Reminders show up in this list."
        static let complete = "Complete Reminder"
        static let completed = "Reminder Completed"
        static let openInReminders = "Open in Reminders"
        static let delete = "Delete Reminder"
        static let deleted = "Reminder Deleted"
        static let deleteConfirm = "Delete"
        static let deleteMessage =
            "It is removed from Reminders on every device that shares this list. You can't undo this."

        static func section(_ group: ReminderGroup) -> String {
            switch group {
            case .overdue: "Overdue"
            case .today: "Today"
            case .upcoming: "Upcoming"
            case .undated: "No Due Date"
            }
        }

        static func dueAt(day: String, time: String) -> String {
            "\(day) at \(time)"
        }

        /// The marks Reminders shows for a priority.
        static func priorityMark(_ priority: ReminderPriority) -> String? {
            switch priority {
            case .high: "!!!"
            case .medium: "!!"
            case .low: "!"
            case .none: nil
            }
        }

        static func deleteQuestion(_ title: String) -> String {
            let shown = title.count > 50 ? title.prefix(49) + "\u{2026}" : Substring(title)
            return shown.isEmpty ? "Delete This Reminder?" : "Delete \u{201C}\(shown)\u{201D}?"
        }
    }

    // MARK: - Forms

    enum Forms {
        static let createEventTitle = "Create Event"
        static let createEventSubmit = "Create Event"
        static let createReminderTitle = "Create Reminder"
        static let createReminderSubmit = "Create Reminder"
        static let title = "Title"
        static let eventTitlePlaceholder = "Event title"
        static let reminderTitlePlaceholder = "What to do"
        static let starts = "Starts"
        static let length = "Length"
        static let calendar = "Calendar"
        static let allDay = "All Day"
        static let due = "Due"
        static let time = "Time"
        static let dateOnlyLabel = "Due on the day, with no set time"
        static let list = "List"
        static let priorityLabel = "Priority"
        static let needsStart = "Choose when the event starts."
        static let needsTitle = "Enter a title."
        static let needsCalendar = "Choose a calendar you can add events to."
        static let needsList = "Choose a list you can add reminders to."
        static let eventCreated = "Event Created"
        static let reminderCreated = "Reminder Created"
        static let noWritableCalendar = "No Calendar Takes New Events"
        static let noWritableCalendarMessage = "Every calendar on this Mac is read-only. Add one in Calendar first."
        static let noWritableList = "No List Takes New Reminders"
        static let noWritableListMessage = "Every list on this Mac is read-only. Add one in Reminders first."

        static func minutes(_ minutes: Int) -> String {
            switch minutes {
            case 60: "1 Hour"
            case 90: "1.5 Hours"
            case let value where value % 60 == 0: "\(value / 60) Hours"
            case let value where value > 60: "\(value / 60) h \(value % 60) min"
            default: "\(minutes) Minutes"
            }
        }

        static func calendarInAccount(_ title: String, _ account: String) -> String {
            "\(title) (\(account))"
        }

        static func priorityName(_ priority: ReminderPriority) -> String {
            switch priority {
            case .none: "None"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    // MARK: - Access

    enum Access {
        static func title(_ permission: Permission) -> String {
            "No Access to \(permission.displayName)"
        }

        static func message(_ permission: Permission) -> String {
            permission == .reminders
                ? "Grant access to Reminders to see your reminders here."
                : "Grant access to Calendars to see your events here."
        }

        static func grant(_ permission: Permission) -> String {
            "Grant Access to \(permission.displayName)"
        }
    }

    // MARK: - Failures

    enum Failure {
        static func accessMissing(_ permission: Permission) -> String {
            "No Access to \(permission.displayName)"
        }

        static let accessMissingReason = "Grant access when asked, or in System Settings, then try again."
        static let notFound = "Reminder Not Found"
        static let notFoundReason = "It may have been completed or deleted on another device."
        static let readOnly = "Read-Only Calendar"
        static let readOnlyReason = "This calendar or list takes no new items. Choose another one."
        static let noCalendar = "No Calendar to Save To"
        static let noCalendarReason = "Add a calendar in Calendar or a list in Reminders, then try again."
        static let calendarGone = "Calendar Not Found"
        static let calendarGoneReason =
            "The calendar or list you chose was removed, so nothing was saved. Choose another one and try again."
        static let saveFailed = "Could Not Save"
        static let saveFailedReason = "Calendar or Reminders did not take the change. Try again in a moment."
    }

    // MARK: - Settings

    enum Settings {
        static let scheduleSection = "My Schedule"
        static let hiddenCalendars = "Hidden calendars"
        static let hiddenCalendarsInfo =
            "Events from the calendars you check stay out of My Schedule and meeting suggestions. Calendars show here once access to Calendars is granted."
        static let hidesAllDay = "Hide all-day events"
        static let hidesAllDayInfo = "Holidays, birthdays and other all-day events stay out of My Schedule."
        static let hidesDeclined = "Hide events you declined"
        static let hidesDeclinedInfo = "Invitations you said no to stay out of My Schedule and are never suggested."
        static let range = "Show the next"
        static let rangeInfo = "How far ahead My Schedule looks, today included."

        static func rangeTitle(_ range: ScheduleRange) -> String {
            switch range {
            case .threeDays: "3 Days"
            case .week: "7 Days"
            case .twoWeeks: "14 Days"
            case .month: "31 Days"
            }
        }

        static let suggestionSection = "Meeting Suggestions"
        static let suggestsMeetings = "Suggest joining meetings"
        static let suggestsMeetingsInfo =
            "When you open the launcher shortly before a meeting with a video link, it offers to join. Nothing pops up by itself."
        static let leadTime = "Suggest from"
        static let leadTimeInfo = "How long before the start the suggestion appears. It stays until five minutes after."

        static func leadTimeTitle(_ lead: MeetingLeadTime) -> String {
            switch lead {
            case .twoMinutes: "2 Minutes Before"
            case .fiveMinutes: "5 Minutes Before"
            case .tenMinutes: "10 Minutes Before"
            case .fifteenMinutes: "15 Minutes Before"
            }
        }

        static let remindersSection = "Reminders"
        static let defaultList = "Default list"
        static let defaultListInfo =
            "Create Reminder starts with this list. Your lists show here after you open My Reminders or Create Reminder once."
        static let remindersDefaultList = "Same as in Reminders"
        static let chosenListNotLoaded = "The List You Chose Before"

        static let accessSection = "Access"
        static let calendarsInfo =
            "My Schedule, Create Event and meeting suggestions need it. You are asked the first time you run My Schedule or Create Event. Suggestions never ask."
        static let remindersInfo =
            "My Reminders and Create Reminder need it. It is asked for the first time you run one of them."
        static let privacyNote =
            "Events and reminders are read from Calendar and Reminders on this Mac when you open My Schedule, My Reminders or a form. While meeting suggestions are on and access to Calendars is granted, root search also reads the next few minutes of your calendars once a minute, to offer a meeting about to start. Nothing is copied or stored anywhere else, and nothing is sent over the network. Settings keep only the IDs of the calendars you hide and the list you pick. Join Meeting opens the meeting's own link in its app or browser."
    }
}
