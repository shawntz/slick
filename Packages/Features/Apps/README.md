# Applications

The reference feature. It puts every installed app and every System Settings pane in root search, and gives app rows the actions people expect from Raycast and Alfred. Read it next to `docs/FEATURES.md`.

## What it declares

| Kind | What |
|---|---|
| Catalog source `app` | one row per installed app, `app:<bundle id>` |
| Catalog source `setting` | one row per Settings pane and per anchor, `setting:<pane id>[?<anchor>]` |
| Command `running` | Running Applications, a list page with the same actions |
| Command `quit-all` | Quit All Applications, behind a confirmation, with a keep-running list |
| Settings pane | extra folders, hidden apps, the panes switch, the keep-running list, a rescan button |

## Where to look

| File | Shows |
|---|---|
| `AppsFeature.swift` | the feature: stored sources, `activate()` with three watch tasks, commands, settings |
| `Sources.swift` | two catalog sources and a list source that share one change signal |
| `AppRows.swift` | rows built off the main thread, with a payload and `represents` |
| `AppActions.swift` | actions built from the row alone, standard actions adjusted with `with(id:)` and `then` |
| `AppLibrary.swift`, `RunningApps.swift` | a feature's own services: protocol, `FeatureServiceKey`, live and isolated |
| `AppScanner.swift`, `SettingsPaneScanner.swift`, `BundleReader.swift` | file work in plain synchronous code, called only from `@concurrent` functions |
| `Tests/AppsTests/AppTree.swift` | a synthetic tree in a temporary folder, and a harness over it |

## Rules this feature follows

- No I/O on the main thread. The scans run in `@concurrent` service methods. `actions(for:)` reads only what the feature already holds.
- Rows are plain values with `memory: .learnOnly`. The catalog offers every app on each read, so root needs no snapshot, and a hidden or deleted app leaves search at once.
- Every side effect goes through Kit's workspace and pasteboard services or one of the two feature services. Tests and scenarios get the simulated running apps and a synthetic tree, so nothing they do can quit an app or read the user's folders.

## Undocumented interfaces

The System Settings rows depend on how macOS lays out its settings panes, which Apple does not document: each pane is an extension in `/System/Library/ExtensionKit/Extensions` with the extension point `com.apple.Settings.extension.ui`, its anchors are the keys of a localized `.searchTerms` property list, and a row opens with an `x-apple.systempreferences:<pane id>[?<anchor>]` link. When a release changes this, the scan finds fewer panes or none, and app rows are not affected. No private function or framework is used.
