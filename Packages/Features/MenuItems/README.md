# MenuItems

Search the menu bar of the app that was in front when the launcher opened, and run a menu item from the keyboard.

Feature ID `menu-items`, class `MenuItemsFeature`. One command, `cmd:menu-items.search`, titled Search Menu Items.

## How it works

- The command pushes a list of every menu item of the app in front. Each row shows the item's title, the menus above it as the subtitle, as in "File › Export", and its shortcut as keycaps.
- Return closes the launcher, waits for the app to be in front with its window key again, then presses the item. Option-Return presses the item's Option alternate, such as Close All for Close Window.
- Items the app has turned off and the Apple menu are hidden unless settings show them. Apps in the leave-out list are never read.
- What was read is kept in memory per app for the session. The next search of the same app shows at once while a fresh read runs behind it.

## Map

| File | Holds |
|---|---|
| `MenuItemsFeature.swift` | manifest, the command, the settings pane, the cache |
| `MenuItemsSettings.swift` | setting keys and the row filter |
| `MenuCache.swift` | the per-app cache with its search index |
| `Strings.swift` | every string a person reads |
| `List/MenuItemList.swift` | the list source: loads, reads, actions, empty states and notices |
| `List/MenuRows.swift` | rows, pages and search, built off the main thread |
| `Model/MenuItem.swift` | items, paths, references, snapshots and limits |
| `Model/MenuShortcut.swift` | the pure function from shortcut attributes to a key combination |
| `Reading/MenuReader.swift` | the reader protocol, its errors and `MenuReaderKey` |
| `Reading/MenuWalker.swift` | the walk both readers share, with its limits |
| `Reading/AccessibilityMenus.swift` | the live reader over Accessibility |
| `Reading/SimulatedMenus.swift` | the isolated reader over menus in memory, and the scenario sample |

## Rules it keeps

- Activation does nothing. The first read happens when the user runs the command, which declares Accessibility, so the host shows its grant card first when access is missing.
- Every Accessibility call runs on one background queue. A walk stops at its time limit, its depth limit and its item limit, when the panel closes, and when its page goes away. The page learns that the panel closed and showed again from the host's page events, not from window notifications.
- Loads never wait for a read. They return the cached menus or a "Reading Menus" state, and the read signals the page when it ends. The list is a `BusySource` that is busy while a read runs, so a scenario's idle wait covers the read.
- Searching and building rows run in `@concurrent` functions. The list filters for itself, a page of 200 rows at a time.
- Rows keep nothing in root search: they hold other apps' titles, such as recent documents.
- A press acts only on the item the row showed. It finds the item by its place, checks the title there, and else looks for the title. A row rebuilt from its ID alone carries its title too, and a press never runs on an item whose title it did not check. Finding the item gives up after 3 seconds.
- A title made only of invisible characters counts as no title, so no row shows one.
- Left-out apps compare by bundle ID without case.

## Tests

`swift test` runs five suites against `SimulatedMenus`. The benchmark runs with `MENUITEMS_BENCHMARK=1`. Nothing in the tests reads or presses a real app's menus.
