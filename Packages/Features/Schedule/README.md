# Calendar and Reminders

The user's calendar and reminders in the launcher: a schedule with meeting links, a suggestion to join a meeting that is about to start, and forms that add events and reminders from a typed phrase. Read it next to `docs/FEATURES.md`.

Nothing is read at launch. Each command needs Calendars or Reminders, and the host asks for it only when the user runs the command and presses Grant.

## What it declares

| Kind | What |
|---|---|
| Command `my-schedule` | My Schedule, events by day from now on, with Join Meeting first when a meeting is close |
| Command `create-event` | Create Event, a form filled from an optional phrase such as "Lunch tomorrow at 1pm"; also a fallback |
| Command `my-reminders` | My Reminders, overdue, today, upcoming and undated, with Complete, Open in Reminders and Delete |
| Command `create-reminder` | Create Reminder, a form filled from an optional phrase; also a fallback |
| Suggestion trigger `meeting-soon` | Join a meeting with a link, from the lead time before it starts until five minutes after, namespace `schedule.meeting` |
| Settings pane | hidden calendars, all-day and declined events, how far ahead, the suggestion and its lead time, the default reminder list, both permissions |

## Where to look

| File | Shows |
|---|---|
| `Store/ScheduleStore.swift` | the feature's own service and its `FeatureServiceKey` |
| `Store/EventKitStore.swift` | the live store, an actor over `EKEventStore` that never asks for access |
| `Store/MemoryScheduleStore.swift` | the isolated store in memory, the test double, and the sample day scenarios show |
| `Store/ScheduleModels.swift` | events, reminders, calendars, drafts and errors as plain values |
| `Links/MeetingLink.swift` | the pure meeting link finder |
| `Events/EventRows.swift` | events into day sections and rows, and the links that open Calendar and Reminders |
| `Events/EventActions.swift`, `ScheduleList.swift` | My Schedule's source and actions |
| `Events/MeetingTrigger.swift` | the suggestion trigger |
| `Reminders/` | My Reminders' rows, source and actions |
| `Forms/Forms.swift` | Create Event and Create Reminder |
| `Shared/NaturalLanguage.swift` | phrases read with `NSDataDetector`, mapped onto the feature's clock |
| `Strings.swift` | every string a person reads |

## Rules this feature follows

- Every side effect goes through `ScheduleStore`. Tests, scenarios and self-tests get `MemoryScheduleStore`, so nothing reads or changes the user's calendars.
- The live store reads the authorization status before every call and throws when access is missing. A command, form or action then returns `.needsPermission`, and an open list offers Grant Access.
- Rows, sections, links and phrases are built off the main thread. `actions(for:)` reads only the row's payload.
- Time comes from the injected clock, so day titles follow the clock's time zone. The one exception is inside `NaturalLanguage`, which reads the system clock only to undo `NSDataDetector`'s own use of it.
- Delete Reminder asks first. Forms save nothing until the user submits. A calendar or list chosen in a form and deleted before the submit is an error: nothing is saved anywhere else.
- An open My Schedule loads again when an event starts or ends and when the day turns, through `refreshAfter`.
- Root search asks the meeting trigger once a minute. While suggestions are on and access is granted, that reads the next few minutes of events. The settings pane says so.
- No network request, no stored copy of events or reminders, no remote icons.
