# Scenarios

Each file here drives the whole launcher end to end: the real panel, the real root search and all sixteen features, in the `scenario` run environment. Services are inert, apps come from the Apps feature's synthetic tree under `com.example`, and data lives in a temporary folder. Each feature serves its own made-up data: a calendar day with a meeting about to start, a few contacts, browser bookmarks, a file index of 3,000 names, dictionary entries, menus of an "Example Editor" and a simulated on-device model.

The run's clock reads UTC and US English, so hours, dates and numbers read the same on every Mac. It follows the real time until a `setTime` step moves it forward.

- `make scenario S=scenarios/<file>` runs one through LaunchServices, with the panel in the bottom-left corner. Results and captures go to `build/scenarios/<file name>`.
- `make scenarios` runs them all.
- `make test-App` runs them all headless, with the panel off screen and a stand-in capture. `SCENARIO_ONLY=calculator,menu-items make test-App` runs only those files.

Run the on-screen targets only while nobody is typing. Each run keeps the panel on screen for well under a second, and a capture with `"key": true` holds key status for about 120 ms.

## Format

Host's format, documented in docs/SCENARIOS.md, plus two file keys and app steps.

| File key | Type | What it does |
|---|---|---|
| `startTime` | string | the run's clock starts at this moment, such as `2026-11-16T00:00:00Z`, so a file that names dates passes on any day |
| `systemApps` | `true` | lists Apple's own apps with their real names and icons, in place of the made-up apps. See "Apple's own apps" |
| `startsBeforeReady` | `true` | runs the first step as soon as the features are activated, before root search and the features finished loading, as a person who types at once after launch does. Without it a run waits for both |

An app step is `{ "app": { ... } }`. Its actions run first, in the order of this table, then its checks, and it fails with every check that does not hold.

| Key | Type | What it does |
|---|---|---|
| `setTime` | string | moves the run's clock forward to this moment, such as `2026-11-16T09:00:00Z`. Root search's hourly tick and every feature's timer wake. A time that is not later than now fails |
| `advanceClock` | number | moves the run's clock forward by this many seconds, more than 0. The page that asks before a link runs a command counts its one-second wait on this clock, so a step with `"advanceClock": 1` comes before a Return on Run or Always Allow |
| `sessionStart` | `true` | plays a wake or an unlock on the run's system context |
| `frontApp` | string | puts the app with this bundle ID in front, for root search's context and for the workspace, as Search Menu Items reads it |
| `pressHotkey` | `true` | does what the launcher hotkey does, through its binding |
| `systemShortcuts` | strings | plays the macOS shortcuts that hold these combinations, as Spotlight holds `cmd+space` on a new Mac; `[]` turns them all off. The launcher notices on its own timer or when settings opens |
| `setFeatures` | object | turns each feature, by ID, on or off, then waits for root search to settle |
| `setSettings` | object | sets `themeName`, `visibleRows`, `inlineCompletion`, `panelSizing`, `launcherHotkey` or `tabCommand`; a name with a dot, such as `windows.showsLayoutName`, sets that feature setting as stored |
| `setHotkey` | object | gives `item` the hotkey `keys`, as settings does; `""` clears it |
| `setFallbacks` | object | as the root search pane does: `order` lists fallback command IDs, such as `cmd:quicklinks.open.wikipedia`, in the new order, and `on` turns each by ID on or off |
| `onboarding` | object | plays onboarding's Optional Features step through its own model: `features` sets each switch by feature ID, then Continue applies them. Onboarding is not marked done |
| `copyAsOtherApp` | strings | another app copies each text in turn onto the run's private pasteboard |
| `makeFiles` | object | writes each made-up text to its path in the run's own home folder, which shows as `~`, making folders on the way. A path that is absolute or climbs out fails, and so does one that is already there |
| `chooseFiles` | strings | the next open dialog hands back these paths in the run's home folder, as if the user chose them there. Each dialog takes the next answer queued; with none left it cancels, and a save dialog always cancels |
| `pressKeys` | string | plays a press of whatever hotkey is registered for these keys |
| `link` | string | opens a deep link; `{scheme}` stands for the app's URL scheme |
| `waitForRow` | string | waits until a row or cell with this title shows on the top page, 5 s at most. For a page that fills itself after its own read and does not say it is busy. Search Menu Items does, so `waitUntilIdle` covers its read |
| `select` | string | selects the row or cell with this title on the top page by pressing Down, then Up, through the runner, as a person would. Fails when no such row shows |
| `waitUntilReady` | `true` | waits until every feature finished the loading its activation started and root search is ready |
| `openSettings` | string | opens the real settings window on this pane at a fixed place: the bottom-left corner of the main screen, inside the area a clip records. The app does not come forward, the window never takes key status and its frame is not saved. Headless runs put it off screen |
| `captureSettings` | string | writes `captures/<name>.png` of the window `openSettings` opened |
| `closeSettings` | `true` | closes that window |
| `openOnboarding` | string | opens the real onboarding window on this step, `welcome`, `hotkey`, `features`, `permissions`, `theme` or `done`, at the place `openSettings` uses, in the same way: the app does not come forward and the window never takes key status. It applies no switch and marks onboarding not done. The launcher hotkey checks at once whether a macOS shortcut holds it, so the hotkey step shows the wait. Fails for a step with nothing to show, such as permissions when no feature that is on needs one |
| `captureOnboarding` | string | writes `captures/<name>.png` of the window `openOnboarding` opened |
| `closeOnboarding` | `true` | closes that window |
| `linkOutcome` | string | the last link was `openedLauncher`, `asked`, `ran`, `openedSettings`, `openedFeatureSettings` or `refused` |
| `launched` | strings | the bundle IDs the workspace was asked to launch, exactly, oldest first |
| `opened` | strings | the URLs the workspace was asked to open, exactly, oldest first |
| `settings` | strings | what settings was asked to open, exactly: a pane, `""` for the last pane, or `features/<id>` |
| `aliases` | object | each item ID has exactly this alias |
| `favorites` | strings | the favorites, exactly, in order |
| `hud` | string | the last HUD's title; HUDs are recorded, never shown; `{brand}` stands for the app's name |
| `pasteboardText` | string | the text on the run's private pasteboard |
| `homeFiles` | strings | each of these paths exists in the run's home folder |
| `openDialogs` | number | how many open dialogs were asked for in the run so far |
| `hotkeyBound` | bool | a launcher hotkey is bound |
| `hotkeyWaiting` | string | the owner of the macOS shortcut the launcher hotkey waits behind, `""` for none |
| `launcherHotkey` | string | the launcher hotkey bound now, such as `cmd+space` |
| `hotkeyRefused` | bool | the last `setHotkey` was refused |
| `itemHotkeys` | object | each item ID has exactly this hotkey; `""` for none |
| `theme` | string | the selected theme, and the panel draws it |
| `featuresActive` | object | each feature, by ID, is active or not |
| `fallbacksOn` | strings | the IDs of the fallbacks that are on, in the order root search shows them |

Host's expectations include `card`: the title of the confirmation or permission card waiting for an answer, `""` for none, and `largeType`: the text Large Type showed last, `""` for none. A `toast` expectation writes `{brand}` for the app's name. Host's `clickLink` step clicks a link the detail shows, by its target. A `tab` press moves into a command's argument chips when they show, as the search field does.

## Apple's own apps

A file with `"systemApps": true` shows Apple's own apps with their real icons and names, so a clip can show real icons and nothing of the person who runs it. It reads only `/System/Applications` and its subfolders one level down, such as `Utilities`: the folder listings, each app's `Contents/Info.plist`, and the localized names the Apps feature reads from each app's own `InfoPlist.loctable` or `en.lproj/InfoPlist.strings`. Platform's live icon renderer draws those apps from their own place and nothing else; a file anywhere else gets its type's generic icon. It never reads `/Applications`, `~/Applications` or anything in the home folder: the Apps feature's tree keeps its folder for other apps empty, and its folder for system apps is a link to `/System/Applications` inside the run's data folder. Deleting the data folder removes the link only.

## Writing a scenario

- Select a row by its title with `{ "app": { "select": "Notes" } }`, never by counting Down presses. A feature that adds or hides a row moves every row below it.
- Wait for idle before a Return that closes the panel when the scenario is about the results, as a person sees them first. A Return pressed while an async section still loads is fine too: closing the panel cancels that section and the root page is idle again.
- Schedule's made-up day has a meeting five minutes after the run's clock starts, so every empty state offers "Join Design Review". A scenario about the empty state turns Schedule off with `setFeatures`.
- Name only made-up apps, people, files and links.

## The files

| File | Proves |
|---|---|
| summon-and-dismiss.json | the launcher hotkey toggles the panel; Escape clears, then dismisses |
| type-and-rank.json | tiers order results, the ghost completion follows typing, Tab accepts it |
| run-app.json | Return and Command-1 run an app, the workspace records it, the panel closes |
| learn-second-result.json | picking a weaker result twice makes it first for that query; rows are picked by title |
| action-panel.json | Command-K lists a row's actions in order and runs the one typed |
| alias.json | Set Alias asks in the search field, stores the alias and the alias finds the item |
| favorite.json | Add to Favorites puts the item in the empty state and the action turns into Remove; Schedule is off so its meeting does not show |
| push-and-back.json | a command pushes its list, which filters, and Escape, Delete and Command-Escape go back |
| open-settings.json | Command-comma and settings links open settings; an unknown pane is refused |
| deep-links.json | a search link selects no row, so Return runs nothing until the user moves; a command link asks with Cancel selected, and Run and Always Allow work after a second; Always Allow is honored and hostile input refused |
| no-results-fallbacks.json | a query with no match offers its fallbacks, their action panel, and the URLs they open |
| long-and-unicode-queries.json | combining marks, emoji, right-to-left text, zero-width spaces and a 520-character query stay intact |
| feature-off-while-shown.json | a feature switched off while its rows show removes them and pops its page |
| alias-equals-title.json | an alias equal to another item's title wins that query |
| hotkey-conflicts.json | item and launcher hotkey conflicts, takeover, retry, and pressing an item hotkey |
| launcher-hotkey-waits.json | while Spotlight holds Command-Space the launcher binds nothing and items are refused; once it is free, opening settings binds it with a HUD |
| theme-switch-while-open.json | a theme switch while the panel and the action panel show |
| themes-beam-and-clear.json | Beam and Clear each draw root search, the action panel, a toast, a pushed list and a form |
| settings-while-pushed.json | settings changed while a list is pushed keep the page and its selection |
| hostile-links-more.json | more hostile links are refused; a command kept out of links is refused without asking; a destructive command by link asks twice, with Cancel selected first |
| two-summons.json | summons and hotkey presses in quick succession |
| clipboard-history.json | copies by another app are listed, filtered and pasted back |
| snippets.json | a snippet made in the panel is found and pasted |
| emoji.json | colon search answers in the first step and pastes; the grid filters and pastes. Every run waits for each feature's own loading before its first step, so the colon index is ready |
| system-commands.json | Restart asks first; Set Volume takes its argument; Toggle Dark Mode reports "Switched to Dark Mode" |
| window-management.json | Switch Windows and repeated Left Half on the simulated desktop |
| quicklinks.json | an argument typed in the search bar opens the right link |
| suggestions-before-typing.json | four days of Calendar at 9:00 with Mail in front and Web Browser at 15:00 with Text Editor in front; on the fifth day the empty state leads with each in its own hour and app |
| calculator.json | a calculation answers at the top, Return copies it with a HUD, and Calculator History keeps it |
| file-search.json | once File Search is on, as onboarding suggests, `~/` lists the made-up home folder, Tab walks into a folder, and a name finds its file |
| dictionary.json | `define lantern` shows the entry, Return opens the definition, Return copies it |
| schedule.json | a meeting about to start is suggested before typing and Return joins its call; My Schedule lists the day with its actions |
| contacts.json | a contact is found by name in Cyrillic and a company by name; Search Contacts calls the number chosen from a submenu |
| bookmarks.json | once Chrome is chosen its bookmarks join root search and open; Search Bookmarks lists them |
| ask-ai.json | Tab asks AI about the typed text, the simulated on-device model answers, Escape returns to root |
| menu-items.json | Search Menu Items lists the menus of the app in front, filters to one item and runs it |
| system-apps.json | with `systemApps`, TextEdit shows by its own name and launches by Apple's bundle ID |
| settings-window.json | the settings window opens on two panes for captures and closes, and the panel still opens after |
| onboarding-window.json | the onboarding window opens on its hotkey step while Spotlight holds the hotkey, then on Optional Features, for captures, and closes, and the panel still opens after |
| two-features-one-query.json | "calendar" shows the Calendar app and Schedule's commands; each row's action panel and Return belong to its own feature |
| onboarding-then-settings.json | File Search switched off in onboarding stays off: no folder listing, no Search Files. Turned on later, both work |
| fallbacks-reordered-and-off.json | the user's fallback order and switches show in root search; a fallback that starts off can be turned on; the choices survive the feature turning off and on |
| hotkey-freed-while-pushed.json | while a page is pushed, the waiting launcher hotkey binds when Spotlight lets go, the HUD says so, the page stays, and the hotkey then toggles the panel |
| deep-links-new-features.json | a link to each command of Calculator, Dictionary, Schedule, Contacts, Bookmarks, AI, Menu Items and File Search asks before it runs; a link to a feature that is off is refused. None of these eight has a hidden command |
| calculator-and-app.json | with `systemApps`, Apple's Calculator app leads "calculator" and launches, the calculator still answers "12 * 12", and "time" leads with Time Machine while the current time answers in its own section |
| typing-at-launch.json | with `startsBeforeReady`, "cal" typed before the apps are scanned keeps the text and shows what is ready; the next keystroke finds Calendar and Return launches it |
| link-session-refusals.json | links to Import Snippets and Import Quicklinks are refused; in a session a search link opened, Return on Import Snippets is refused with a toast and asks for no file, while the next session the user opens runs it; a destructive question in a link session starts on Cancel, so Return cancels it |
| dropdown-value-refused.json | a link that gives Clear Recent Clipboard History a period it does not offer asks first, then is refused with a toast that names the argument, and the history keeps its item |
| detail-links.json | in an Ask AI answer, a web link opens at once and a link to another app's scheme shows its full target in a toast first; the toast's Open, first in the action panel, opens it |
| large-type.json | a calculator answer offers Show in Large Type, and Command-L closes the panel and shows "144" in Large Type |
| file-actions.json | with File Search on, a made-up file in the run's home folder offers every file action, and Command-D duplicates it twice as "plan copy.rs" and "plan copy 2.rs", never over another file |
| import-snippets.json | Import Snippets reads a made-up Raycast file from the open dialog, lists two to add and one not valid, imports on Return with a toast of the counts, and the new snippet is found in root search |
| import-quicklinks.json | Import Quicklinks reads a made-up Raycast file, imports the web link and turns off the one for another app, which root search then does not offer |

`FastTypingTests` in App's tests adds a slow async provider to the joined app and types faster than it answers. `OneItemTwoRowsTests` adds a file search that finds an app's own bundle, which the scenario environment's file index cannot hold, and checks that the app shows once.
