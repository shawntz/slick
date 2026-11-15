import Foundation
import Kit

/// The actions of an event row and a meeting suggestion, built from the row's ``EventSummary``.
enum EventActions {
    /// Join Meeting comes first from this long before the start until the end.
    static let joinFirstFrom: TimeInterval = 15 * 60
    static let copyDetailsShortcut = KeyCombo(.c, [.option, .command])

    /// My Schedule's actions: Join Meeting first when the meeting is about to start or running,
    /// otherwise Open in Calendar first and Join Meeting on Command-Return.
    static func actions(for summary: EventSummary, now: Date, text: TimeText) -> [Action] {
        let open = openInCalendar(summary)
        var actions: [Action]
        if let link = summary.link {
            let join = join(link)
            actions = joinsFirst(summary, now: now) ? [join, open] : [open, join]
        } else {
            actions = [open]
        }
        actions.append(copyDetails(summary, text: text))
        if let link = summary.link { actions.append(copyLink(link)) }
        return actions
    }

    /// A suggestion's actions: Join Meeting, Open in Calendar and Copy Meeting Link.
    static func suggestionActions(for summary: EventSummary) -> [Action] {
        guard let link = summary.link else { return [openInCalendar(summary)] }
        return [join(link), openInCalendar(summary), copyLink(link)]
    }

    /// True when Join Meeting is the primary action at `now`.
    static func joinsFirst(_ summary: EventSummary, now: Date) -> Bool {
        summary.link != nil && now >= summary.start.addingTimeInterval(-joinFirstFrom) && now < summary.end
    }

    static func join(_ link: MeetingLink) -> Action {
        Action(Strings.Actions.joinMeeting, id: "join", icon: .symbol("video.fill")) { context in
            try await context.workspace.open(link.url)
            return .close()
        }
    }

    /// Shows the event in Calendar, or opens Calendar when the event's link does not work.
    static func openInCalendar(_ summary: EventSummary) -> Action {
        Action(Strings.Actions.openInCalendar, id: "open-in-calendar", icon: .symbol("calendar"), shortcut: .open) {
            context in
            if let url = CalendarAppLinks.event(externalID: summary.externalID, eventID: summary.eventID),
                (try? await context.workspace.open(url)) != nil
            {
                return .close()
            }
            try await context.workspace.launch(bundleID: CalendarAppLinks.calendarBundleID)
            return .close()
        }
    }

    static func copyDetails(_ summary: EventSummary, text: TimeText) -> Action {
        Action.copy(
            details(summary, text: text), title: Strings.Actions.copyDetails, hud: Strings.Actions.copiedDetails,
            shortcut: copyDetailsShortcut
        ).with(id: "copy-details")
    }

    static func copyLink(_ link: MeetingLink) -> Action {
        Action.copy(
            link.url.absoluteString, title: Strings.Actions.copyMeetingLink, hud: Strings.Actions.copiedMeetingLink,
            shortcut: .copy
        ).with(id: "copy-link")
    }

    /// The event as plain text: title, when, where and the link, one per line.
    static func details(_ summary: EventSummary, text: TimeText) -> String {
        var lines = [summary.title.isEmpty ? Strings.Schedule.untitled : summary.title]
        lines.append(when(summary, text: text))
        if let location = summary.location, location != summary.link?.url.absoluteString { lines.append(location) }
        if let link = summary.link { lines.append(link.url.absoluteString) }
        return lines.joined(separator: "\n")
    }

    /// "Saturday, November 14, 10:00 AM – 10:30 AM", or the start and end days for a longer event.
    static func when(_ summary: EventSummary, text: TimeText) -> String {
        let startDay = text.day(summary.start)
        let lastMoment = summary.end > summary.start ? summary.end.addingTimeInterval(-1) : summary.start
        let endDay = text.day(summary.isAllDay ? lastMoment : summary.end)
        if summary.isAllDay {
            return startDay == endDay ? Strings.Details.allDay(startDay) : Strings.Details.span(startDay, endDay)
        }
        if startDay == endDay { return Strings.Details.sameDay(startDay, text.range(summary.start, summary.end)) }
        return Strings.Details.span(
            Strings.Details.dayAndTime(startDay, text.time(summary.start)),
            Strings.Details.dayAndTime(endDay, text.time(summary.end)))
    }
}
