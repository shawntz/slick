# Clipboard History

Keeps what you copy in other apps, lets you search it, and pastes it back. Feature ID `clipboard`, class `ClipboardHistoryFeature`. It is on by default.

## What it declares

| Kind | What |
|---|---|
| Command `history` | Clipboard History: a list with a detail pane, a type dropdown, Pinned then one section per day, a page at a time |
| Command `clear-history` | Clear Clipboard History, behind a confirmation. Pinned items stay |
| Command `clear-recent` | Clear Recent Clipboard History, with a period of 5 minutes, 15 minutes, an hour or 24 hours, behind a confirmation |
| Command `toggle-recording` | Pause Clipboard Recording, or Resume Clipboard Recording while paused |
| Suggestion trigger `recent-copy` | for two minutes after a copy, offers to paste it |
| Provided service | `.clipboardHistory`, which answers `{clipboard offset=N}` from the whole history |
| Settings pane | pause, retention, item cap, image space, Return key, move to top, ignored apps, Clear History |

## Where to look

| File | Shows |
|---|---|
| `ClipboardHistoryFeature.swift` | the feature: the monitor's start and stop, commands, settings pane, status |
| `Recorder.swift` | the monitor: one `@concurrent` function per pasteboard entry, the ignore list, pruning |
| `Capture.swift` | what a copy keeps, its kind and its key |
| `HistoryStore.swift`, `HistorySchema.swift` | SQLite with a trigram full-text index, images and thumbnails as files beside it |
| `HistoryList.swift`, `HistoryRows.swift`, `HistoryDetail.swift` | the page, its rows and sections, its detail pane |
| `HistoryActions.swift` | every action, built from the row's payload |
| `RecentCopyTrigger.swift` | the suggestion and the reader other features use |
| `Strings.swift` | every string a person reads |

## Rules this feature follows

- It stores only what `PasteboardService.entries()` hands over. The service drops concealed, transient and auto-generated items and what this app wrote. The monitor never reads the pasteboard itself.
- No file or database work runs on the main thread. The monitor's task is detached and records in a `@concurrent` function. The store is an actor. Rows and details are built in `@concurrent` functions.
- An item's row ID is a hash of its content, `clipboard:<16 hex digits>`, so it stays the same when the item moves to the top or the app restarts.
- Pausing ends the pasteboard stream, so the live service stops polling.
- Pinned items are never pruned.
- A database SQLite cannot read is moved, with its images, into `damaged-N` beside it, and a new history starts. Nothing is deleted.
- The permission watch, which polls in the live app, runs only while Paste from Other Apps is missing.
