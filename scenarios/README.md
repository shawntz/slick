# Scenarios

Each file here drives the whole launcher end to end: the real panel, the real root search and the real features, in the `scenario` run environment. Services are inert, apps come from the Apps feature's synthetic tree under `com.example`, and data lives in a temporary folder.

- `make scenario S=scenarios/<file>` runs one through LaunchServices, with the panel in the bottom-left corner. Results and captures go to `build/scenarios/<file name>`.
- `make scenarios` runs them all.
- `make test-App` runs them all headless, with the panel off screen and a stand-in capture.

Run the on-screen targets only while nobody is typing. Each run keeps the panel on screen for well under a second, and a capture with `"key": true` holds key status for about 120 ms.

## Format

Host's format, documented in docs/SCENARIOS.md, plus app steps. An app step is `{ "app": { ... } }`. Its actions run first, then its checks, and it fails with every check that does not hold.

| Key | Type | What it does |
|---|---|---|
| `pressHotkey` | `true` | does what the launcher hotkey does, through its binding |
| `systemShortcuts` | strings | plays the macOS shortcuts that hold these combinations, as Spotlight holds `cmd+space` on a new Mac; `[]` turns them all off. The launcher notices on its own timer or when settings opens |
| `setFeatures` | object | turns each feature, by ID, on or off, then waits for root search to settle |
| `setSettings` | object | sets `themeName`, `visibleRows`, `inlineCompletion`, `panelSizing` or `launcherHotkey`; a name with a dot, such as `windows.showsLayoutName`, sets that feature setting as stored |
| `setHotkey` | object | gives `item` the hotkey `keys`, as settings does; `""` clears it |
| `copyAsOtherApp` | strings | another app copies each text in turn onto the run's private pasteboard |
| `pressKeys` | string | plays a press of whatever hotkey is registered for these keys |
| `link` | string | opens a deep link; `{scheme}` stands for the app's URL scheme |
| `linkOutcome` | string | the last link was `openedLauncher`, `asked`, `ran`, `openedSettings`, `openedFeatureSettings` or `refused` |
| `launched` | strings | the bundle IDs the workspace was asked to launch, exactly, oldest first |
| `opened` | strings | the URLs the workspace was asked to open, exactly, oldest first |
| `settings` | strings | what settings was asked to open, exactly: a pane, `""` for the last pane, or `features/<id>` |
| `aliases` | object | each item ID has exactly this alias |
| `favorites` | strings | the favorites, exactly, in order |
| `hud` | string | the last HUD's title; HUDs are recorded, never shown; `{brand}` stands for the app's name |
| `pasteboardText` | string | the text on the run's private pasteboard |
| `hotkeyBound` | bool | a launcher hotkey is bound |
| `hotkeyWaiting` | string | the owner of the macOS shortcut the launcher hotkey waits behind, `""` for none |
| `launcherHotkey` | string | the launcher hotkey bound now, such as `cmd+space` |
| `hotkeyRefused` | bool | the last `setHotkey` was refused |
| `itemHotkeys` | object | each item ID has exactly this hotkey; `""` for none |
| `theme` | string | the selected theme, and the panel draws it |
| `featuresActive` | object | each feature, by ID, is active or not |

Host's expectations gained `card`: the title of the confirmation or permission card waiting for an answer, `""` for none. A `tab` press moves into a command's argument chips when they show, as the search field does.

## The files

| File | Proves |
|---|---|
| summon-and-dismiss.json | the launcher hotkey toggles the panel; Escape clears, then dismisses |
| type-and-rank.json | tiers order results, the ghost completion follows typing, Tab accepts it |
| run-app.json | Return and Command-1 run an app, the workspace records it, the panel closes |
| learn-second-result.json | picking the second result twice makes it first for that query |
| action-panel.json | Command-K lists a row's actions in order and runs the one typed |
| alias.json | Set Alias asks in the search field, stores the alias and the alias finds the item |
| favorite.json | Add to Favorites puts the item in the empty state and the action turns into Remove |
| push-and-back.json | a command pushes its list, which filters, and Escape, Delete and Command-Escape go back |
| open-settings.json | Command-comma and settings links open settings; an unknown pane is refused |
| deep-links.json | links open the launcher, ask before running a command, honor Always Allow and refuse hostile input |
| no-results-fallbacks.json | a query with no match offers its fallbacks, their action panel, and the URLs they open |
| long-and-unicode-queries.json | combining marks, emoji, right-to-left text, zero-width spaces and a 520-character query stay intact |
| feature-off-while-shown.json | a feature switched off while its rows show removes them and pops its page |
| alias-equals-title.json | an alias equal to another item's title wins that query |
| hotkey-conflicts.json | item and launcher hotkey conflicts, takeover, retry, and pressing an item hotkey |
| launcher-hotkey-waits.json | while Spotlight holds Command-Space the launcher binds nothing and items are refused; once it is free, opening settings binds it with a HUD |
| theme-switch-while-open.json | a theme switch while the panel and the action panel show |
| settings-while-pushed.json | settings changed while a list is pushed keep the page and its selection |
| hostile-links-more.json | more hostile links are refused; a destructive command by link asks twice |
| two-summons.json | summons and hotkey presses in quick succession |
| clipboard-history.json | copies by another app are listed, filtered and pasted back |
| snippets.json | a snippet made in the panel is found and pasted |
| emoji.json | the grid and colon search paste the right emoji; the grid runs first, because the colon answer waits for the data the grid loads |
| system-commands.json | Restart asks first; Set Volume takes its argument; Toggle Dark Mode reports |
| window-management.json | Switch Windows and repeated Left Half on the simulated desktop |
| quicklinks.json | an argument typed in the search bar opens the right link |

`FastTypingTests` in App's tests adds a slow async provider to the joined app and types faster than it answers.
