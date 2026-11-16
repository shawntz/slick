# Slick architecture

Slick is a native macOS launcher. One hotkey opens one search field, and everything on the Mac sits behind it. It is open source under the MIT license.

This document is the contract for everyone who works on the code, human or agent. If the code and this document disagree, fix one of them in the same change.

## Goals

1. **Speed.** Slick does less than 5 ms of main-thread work per keystroke at p99 and puts no I/O on the summon path, so every keystroke lands on the next frame the window server can show.
2. **Real Liquid Glass.** The window is an `NSGlassEffectView`. No blur imitations.
3. **Prediction.** Slick learns which result you pick for each query and what you open in each context, and ranks with that. Learning never leaves the machine.
4. **A complete core.** The built-ins people rely on in Raycast and Alfred ship in the box: apps, files, clipboard history, snippets, window management, calculator, system commands, quicklinks and web search, emoji, script commands, hotkeys and aliases.

Not goals for now: a React extension runtime, cloud sync, accounts, telemetry.

## Facts the design rests on

Measured on macOS 27.2, Apple M5, 120 Hz display, November 2026. Every number below was reproduced by a second, independent run.

| Fact | Number | What it forces |
|---|---|---|
| The window server adds 1 to 2 refreshes to any change | commit to screen 11 to 14 ms p50 | "One frame end to end" is impossible. We budget main-thread time so a keystroke always catches the next refresh. Realistic on-screen latency is about 17 ms p50, 25 ms p99. |
| Keystroke work with a TextKit 1 field and one Core Text list view | lab 2.2 ms p50, 4.2 ms p99 main thread. In the real panel 3.2 ms p50, 9 ms p99, of which the field editor is about 2 ms | This is the list implementation. NSTableView costs 17 ms, SwiftUI 10 to 16 ms, pooled label views 6 ms. The field editor is now the largest cost and the next thing to replace. |
| Resizing the glass | 2 to 3.2 ms of main-thread time per display-link tick | The panel never resizes while the user types. See "Panel sizing". |
| Root query over 10,000 items in the engine, with ranking and top 50 | 82 µs p50, 190 to 310 µs p99 on performance cores. About 1.2 ms p99 at background priority, the slowest the scheduler can make it | Root search runs synchronously on the main thread. Queries of two or three characters cost the most. |
| A Swift to Rust call | 0.47 ns | The FFI is free. Shape the API for clarity. |
| Summon by flipping root-layer opacity on a panel that stays ordered in | first pixels 10 to 12 ms p50, against 17 to 19 ms for `orderFront` | Default summon strategy. |
| The glass's key look is a layer AppKit turns on in the first layout after the window becomes key, and the render server shows it two refreshes after its commit | a panel shown before `makeKey` showed flat glass for 1 to 3 refreshes, a bright flash in dark mode on 39 of 40 summons | The summoner makes the panel key and commits the key look while the panel is still invisible, then flips the opacity. First pixels are the finished look at 22.7 ms p50. Before, a flat frame came at 10 ms and the finished look at 24.9 ms. |
| `makeKey` | 1.8 ms p50, up to 20 ms p99 | This is window server time. Nothing else may sit on the summon path. |
| Glass shows its full look only while its window is key | a key non-activating panel matches an active app pixel for pixel | One key panel. Menus, previews, confirmations and forms all live inside it. |
| The glass draws its own shadow outside its shape | visible to 24 pt above, 32 pt beside, 48 pt below | The window is larger than the glass by those insets and transparent there. |
| Core Animation bounds animation breaks the glass shape | | A display link drives glass height. Position springs are fine. |
| Custom-drawn text gets no glass vibrancy | only `NSTextField` labels do | The theme owns text contrast. See "Glass rules". |
| The main thread runs mostly on efficiency cores while typing | CPU time varies 1.5 to 2.5 times between runs | Budgets carry 2 times headroom. Benchmarks run as a LaunchServices app, never as a terminal binary. |
| Worker threads of a hidden app run on efficiency cores | about 2.2 times slower | Background indexing is slow by design. Nothing interactive waits on it. |
| Spotlight name queries with home scope | first batch 130 to 1,600 ms, outliers past 8 s | Slick keeps its own file index. Spotlight is for content search. |
| Scanning the app folders | 0.6 ms for 268 apps | Rescan everything on any change. No incremental patching. |
| Icons from an mmap'd BGRA atlas | 0.19 ms for 270 icons, against 38 ms for PNG files | The main thread only looks icons up. It never fetches or decodes one. |
| Pasteboard | no change notification exists, a `changeCount` read costs 0.4 µs, no alerts on 27.2 | Poll at 4 Hz off the main thread. |
| No crate ranks like a launcher | best crate 34 of 45 held-out expectations, ours 39 | The matcher is in-house. |

The full lab notes are not in the repository. The numbers that matter are restated where the code depends on them.

## Layout

```
core/                         Cargo workspace
  crates/slick-match          fuzzy matcher: arena, tiers, top-k, highlight ranges
  crates/slick-predict        learning: query affinity, zero-query model, event log
  crates/slick-engine         catalog, ranking contract, sessions, suggestions, generic indexes
  crates/slick-calc           calculator, units, dates, time zones
  crates/slick-files          file index: walker, mmap store, path-aware search
  crates/slick-ffi            the only staticlib. C ABI, one module per area, generated header
Packages/                     one SwiftPM package per module
  CoreBridge                  C module plus Swift wrappers over the staticlib
  Kit                         contracts: values, feature and view protocols, service protocols, test fakes.
                              Its KitHosting target holds the contracts between the app's own packages
  LauncherUI                  pure AppKit rendering: glass panel, query field, list, grid, lens, action bar, detail pane
  Platform                    live implementations of Kit services: pasteboard, workspace, hotkeys, permissions, icons
  Host                        the feature runtime, and Kit views on LauncherUI: navigation, action panel, forms, scenario runner
  Root                        root search: engine queries, live providers, suggestions, favorites, aliases, fallbacks, learning
  SettingsUI                  settings window, onboarding, hotkey recorder
  Updates                     the updater: Sparkle, behind KitHosting's UpdateControl
  Features/<Name>             one package per feature
  App                         the executable: wiring, feature list, status item, deeplinks, entry points
support/                      Info.plist, entitlements, app icon source
scripts/                      build-rust, bundle, run, selftest, scenario, bench
docs/                         this file and friends
```

## Dependency rules

```
Features/*  ->  Kit                         always
Features/*  ->  LauncherUI                  only for a feature that owns its own window
Features/*  ->  CoreBridge                  only for a feature with its own Rust module
Platform    ->  Kit
SettingsUI  ->  Kit, LauncherUI
Host        ->  Kit, LauncherUI
Root        ->  Kit, CoreBridge
Updates     ->  Kit, and Sparkle 2.9.6, the only remote dependency
App         ->  everything
Kit         ->  nothing
LauncherUI  ->  nothing
CoreBridge  ->  nothing in Swift, links libslick_ffi.a
```

- A feature never imports another feature, `Host`, `Root`, `Platform` or `App`. Features talk to each other through Kit contracts.
- `Host`, `Root`, `Platform` and `SettingsUI` never import each other. They meet through the protocols in `KitHosting`, and `App` connects them. A feature never imports `KitHosting`.
- Only `Updates` imports Sparkle. Its manifest pins Sparkle to one exact version from github.com/sparkle-project/Sparkle, and its `Package.resolved`, like `App`'s, is committed, so every build links the same revision. `scripts/check-manifests.sh` fails on any other remote dependency.
- Only `CoreBridge` sees the C header. Only `slick-ffi` exports symbols.
- `LauncherUITesting` is for tests, demos and captures. The one product use is the recording build of Host, compiled only when `SCENARIO_RECORDING=1`, so the app links none of it.
- `Kit` and `LauncherUI` stay small, because every package that depends on them compiles its own copy.
- New code goes in a new file. Shared files that many people touch, such as the feature list in `App`, change one line at a time.

One package per module is deliberate. A syntax error in one feature cannot stop another feature's tests, and two people building different packages never wait on the same lock.

## The core

### Matching

`slick-match` holds each corpus in a flat structure-of-arrays arena of case-folded, diacritic-folded bytes. Text is composed first, so a name stored decomposed folds and highlights like the same name composed. Per item it stores a 64-bit character-presence mask, a word-initials mask and a word-start bitmap. A query runs mask prefilter, then NEON occurrence bitmaps, then tier classification, then top-k with a running threshold. A session narrows: when the query grows, only the previous match set is re-scored. Highlight ranges are computed for visible rows only and come back as UTF-16 offsets.

Text tiers, strongest first:

| Tier | Meaning | Example |
|---|---|---|
| exact | folded title equals folded query; in a feature's list, a keyword equal to it counts too, below an exact title | `safari` and Safari |
| prefix | title starts with the query, or the query covers leading words in order | `saf`, `vsc`, `vs code` |
| word-prefix | acronyms, camelCase, skipped words | `gc` and Google Chrome |
| unordered | every token starts a word, any order | `mode dark` |
| substring | contiguous, mid-word | `fari` |
| typo | one Damerau edit at a word start | `calender` |
| subsequence | scattered | `sfr` |

The typo pass runs when the best strict tier found is weaker than word-prefix. It is not gated on a result count. A typo match ranks above a scattered subsequence, so `calender` finds Calendar and `musc` finds Music.

### Ranking contract

Every ranked list in Slick obeys these rules. Constants live in `slick-engine` and are tuned with the simulator in `slick-predict`. The rules do not move.

1. A user alias that matches exactly or by prefix ranks first.
2. Next comes the learned band. An item enters it when it is the strongest entry in the affinity row for exactly this query and its decayed weight is at least 1.1, and then holds it as rule 4 says. This sits above an exact title match on purpose. If you typed `term` twice and picked Terminal both times, Terminal wins `term`, even if another app is named Term.
3. Outside those two bands, a weaker text tier never outranks a stronger one. Frecency, context and kind priors only reorder within a tier. Query affinity outside the band may lift an item by at most one tier.
4. A habit flips in two selections. One stray pick never flips it. This holds from any history: the item that holds the learned band for a query changes only when another item gets two credits in a row for that query and is then the strongest entry, or when the holder's weight falls below 1.1, from time or from other picks. Credit from a longer query that starts with this one counts.
5. The same query against the same state returns the same order. Ties break by shorter title, then by key.

### Learning

- **Query affinity.** When you run item `y` after typing `q`, every prefix of `q` gets credit: 1 for `q` itself, 0.5 for shorter prefixes. Each row is an exponential moving histogram with self-decay 0.7 per credit and a 60-day time decay, at most 8 items per row.
- **Zero-query model.** A log-linear product of experts over frecency at two half-lives, recency, novelty and conditional counts for context features: hour bucket, weekday, the app that was frontmost at summon, the previous item and the time since it, power, displays, audio route. Exponents start at population priors and adapt online with softmax SGD.
- **Seeding.** On first run the model takes light priors from Spotlight use counts, the Dock and running apps. No permission prompt is involved. App gathers them off the main thread and passes them to Root. Root reads none of those sources itself.
- **Proactive triggers.** Features may offer situational suggestions, such as joining a meeting that starts in five minutes. Triggers use Thompson sampling with at most one inserted row, two for an imminent meeting, and switch themselves off when acceptance stays low.
- Suggestions are computed when the context changes, not when the hotkey fires. The frontmost app is never suggested.

### Persistence

The engine keeps an append-only log of 32-byte event records with a CRC, plus a versioned snapshot. Startup loads the snapshot and replays only the log records after it, with full updates, so a replay equals the live state. Writes happen off the main thread. A corrupt tail is truncated, never fatal. A second engine on the same directory is refused through a lock file. The store thread keeps its own copy of the learning state and snapshots from that, so a snapshot never makes a record call wait. The log is compacted and the two latest snapshots are kept. Without a usable snapshot an uncompacted log is replayed in full, about 800 ms at 50,000 events, so the app opens the engine off the main thread. A compacted log with no readable snapshot cannot be replayed: the engine starts empty and keeps the log beside it as `events.unreadable.log`.

### Keys

An item's identity is a namespaced string such as `app:com.apple.Safari`, `cmd:clipboard.history` or `file:/Users/me/notes.md`. The engine key is the 64-bit FNV-1a hash of its UTF-8 bytes. Swift computes it. Rust never sees the string.

### FFI conventions

- Strings cross as UTF-8 pointer plus length. No NUL termination, no ownership transfer.
- The caller owns every buffer. The query path allocates nothing. That holds for a file search on one thread once its session is warm: the searcher keeps the memory of its largest match sets, about 8 MB at a million entries. In parallel the parts race for the running threshold, which decides how many entries a set holds, so a set can still grow now and then until it has seen its largest size. No search allocates as a matter of course.
- Every exported function returns an `i32` status and wraps its body in `catch_unwind`. A panic comes back as a status code, never as an abort.
- `slick_abi_version()` is checked at launch. It goes up whenever the header changes, and stands at 4.
- A walk of the file index takes a cancel flag that every walker thread checks once per folder. A cancelled walk publishes nothing.
- File search spreads its work with `dispatch_apply_f` inside Rust, at the caller's quality of service. No thread pool is linked. Call it from a user-initiated queue.
- One Rust module per area in `slick-ffi`: `engine.rs`, `index.rs`, `calc.rs`, `files.rs`. The header is generated by cbindgen, committed, and checked for drift in CI.
- `scripts/build-rust.sh` installs the staticlib with an atomic rename, so a Swift link never sees a half-written file.

## Swift packages

### Kit

Kit is the vocabulary every feature is written in. It has no dependencies. Features describe; the host draws.

- **Values.** `ItemID`, `Row`, `ListSection`, `Payload`, `Icon`, `Accessory`, `KeyCombo`, `Detail`, `Toast`, `HUD`, `Selection`. All `Sendable`. Rows are plain data, built on any thread. A row carries its item in memory as a `Payload`, says what root search keeps (`memory`), when it expires, what it stands for (`represents`, which brings every feature's universal actions to it), match highlights and an in-tier `rankHint`.
- **Behavior.** `Action` and `ActionOutcome`, `Command` with up to three inline arguments, a confirmation and row actions. Actions come from the source that made the row, never from the row. The host checks `requires`, asks the confirmation, runs handlers under a `RunPolicy` (serial per feature by default), shows thrown errors as failure toasts, draws toasts as HUDs while the panel is closed, and does not cancel a handler when the panel closes. Outcomes close, push, replace, pop, return to root with a query, run another command, show text in Large Type, or ask the host to run its permission card.
- **Features.** A `Feature` declares a manifest, commands, catalog sources, live providers, suggestion triggers, universal actions, a settings pane, hotkey presets, a status for settings and the services it provides to other features. The host reads declarations at registration and after `declarationChanges`; sources and providers are stored objects.
- **Root search inputs.** A catalog source pushes rows that the engine matches synchronously. A live provider answers per keystroke, either instantly on the main thread within 100 µs, or asynchronously with cancellation. A suggestion trigger offers situational rows. Each names a namespace that routes remembered rows back to it; one object may hold one namespace in several roles. List, catalog and suggestion sources share `RowSource`: a `ChangeSignal` and the settings that reload them.
- **Views.** A command can push a list, a grid, a detail or a form. Lists filter in the host, with section visibility, a title match before a keyword match inside a tier, then rank hints, or in the source, with paging and highlights, and may replace their filter dropdown or show a notice. Detail sources stream updates and build actions from the detail shown.
- **Services.** Everything with a side effect sits behind a protocol on `FeatureContext`: pasteboard, workspace, hotkeys, permissions (status and changes), process runner, HTTP, storage paths, settings, secrets, clock, usage tracking, fuzzy indexes, selection, file watching, file dialogs, text expansion. Async requirements that do work are `@concurrent`. A service only one feature uses is named by a `FeatureServiceKey`, which picks the live or isolated implementation per run environment and takes a test override. Each Kit service has a fake in `KitTesting`, which also holds `FeatureHarness`; `settle()` waits until a feature's background loops have handled what the fakes sent. Optional weight lives in separate targets: `KitStorage` (SQLite with cancellable queries, atomic JSON files) and `KitTemplates` (placeholders).
- **Run environment.** `live`, `scenario`, `selftest`, `bench`. Outside `live`, side effects go to fakes and features get the isolated implementation of their own services.

A page's source can learn that its page is shown again and that the panel closed, through `PageEvents`. A source busy with work of its own between loads, such as a read of another app's menus, adopts `BusySource`; scenarios, the selftest and benchmarks wait while it is busy. A feature hears through `permissionGranted` when a permission it declares was granted in settings, onboarding or the panel's card, so it need not hold a permission stream. A feature that is off by default can ask to be suggested in onboarding, where its switch then starts on. `DisplayText.fileName` turns any file name into text that is safe to show. A command may stay out of deep links with `allowsDeepLinks: false`, which hidden commands that act at once use. A settings picker may ask before a choice that deletes data. The validator reports a hidden command that asks nothing and still allows deep links. A feature that loads an index or data after activation implements `waitUntilReady()`. Scenarios, the selftest and benchmarks wait for it. The live launcher never does: it shows what has loaded.

Root search reserves the namespaces `cmd` and `app`. The Apps feature, and only it, may use `app`, because it owns those rows.

Exact signatures live in the code. `docs/FEATURES.md` walks through writing a feature.

**KitHosting** is a separate target for the contracts between the app's own packages. It depends on Kit only and has no default isolation; the protocols the UI touches are `@MainActor`. Features never import it.

- `FeatureDirectory`: every registered feature as a `FeatureEntry` in registration order, on or off, with its manifest, context, declarations and `CommandEntry` list, plus a change signal. Host's runtime implements it. Root and SettingsUI read it.
- `ItemPreferences`: what the user attached to items, which is aliases, hotkeys, favorites and feature and command switches. Setting a hotkey binds it, takes it over from another item, and throws `HotkeyError` for a conflict that cannot be overridden. Host implements it. Root reads aliases and favorites. SettingsUI edits all of it.
- `RootSource`: root search as the panel drives it. `begin()` returns the prepared empty state on the summon path, `update(query:)` runs inside the keystroke, `snapshot` and `changes` carry sections that arrive late, and `end()` cancels. A `RootSnapshot` holds `RootSection`s, a `RootCompletion`, a loading flag, an empty state and a revision. It also gives highlights for rows that scroll into view, a row's feature, a row by ID, and run and forget records. It returns no actions for command rows, because Host runs commands itself, and the section kind sets the launch source. Root implements it. Host drives it.
- `LearningInspector`: what the engine learned, with a summary, top items, learned queries, the suggestion triggers with a reset for each, forget, pause and erase. A learned query says which item holds its top band. Root implements it. SettingsUI shows it.
- `IconProvider`: icon lookups that never read the disk or decode on the main thread. Nil means not ready; the provider loads off the main thread and signals. Platform implements it. Host and SettingsUI draw with it.
- `SystemContextService`: the frontmost app, power, displays, audio route and Focus, with a stream of changes and one of session starts. Platform implements it. Root feeds the engine with it.
- `LoginItemControl`: whether the app opens at login. Platform implements it. SettingsUI shows it.
- `UpdateControl`: whether this build updates itself, whether it checks automatically with a setter for the person's switch, the time of the last check, the version a scheduled check found that waits, and a check now. `NoUpdates` beside it is the do-nothing implementation every run but one uses. Updates implements the real one. SettingsUI shows it in the General pane and onboarding, and App's menu bar item offers it.
- `HostSettings`: the typed keys of the general settings that more than one package reads, stored under the `app.general` namespace.
- `LinkAllowances`: the commands links may run without asking, each with its exact arguments and title, under `app.links`. App's router writes it. SettingsUI lists and removes it.

`KitHostingTesting` holds a fake for each, and `FakeFeatureDirectory.register` and `FeatureEntry.make` build entries from real features over `FakeServices`, so Root and SettingsUI tests need no Host.

### LauncherUI

LauncherUI draws. It knows nothing about features, the engine or Kit. It takes display structs with resolved text, images and highlight ranges, and it reports key and pointer events upward.

- `GlassPanel`: borderless non-activating panel, `canBecomeKey` true, `canBecomeMain` false, fixed size with transparent insets, one `NSGlassEffectView` with corner radius 26.
- `Summoner`: pre-warms at launch, keeps the panel ordered in, makes the panel key and commits the glass's key look while it is still invisible, then shows it by flipping root-layer opacity inside one transaction. `makesKeyBeforeShowing = false` restores the old order, which shows a frame sooner and flashes flat glass. `orderFront` stays available behind a setting.
- `QueryField`: `NSTextField` with a tuned TextKit 1 field editor, ghost completion and inline argument chips. The field editor stays installed. Nothing calls `makeFirstResponder` on the summon path.
- `ResultListView`: one view that draws every visible row with Core Text, diffs per row, and builds accessibility elements on demand.
- `GridView`, `DetailPane` (beside the list in `ListDetailView`), `FormView` and `EmptyStateView` fill the content area. `ActionCardView`, `ConfirmCardView` and `DropdownMenuView` are `PanelOverlay`s that `LauncherSurface.present(_:)` draws inside the panel. A confirm card can start on Cancel, so Return cancels until Tab moves to the confirm button. `ActionBar` shows toasts and `KeycapView` shortcuts; `HUDWindow` confirms an action after the panel closes.
- `LargeTypeWindow` shows a text in very large letters on the screen with the pointer. `LargeTypeLayout` sizes it to about 80 percent of the screen's width, `LargeTypeStyle` gives it a dark rounded backing from the theme, and `LargeTypeDismissal` hides it on any key, any click or a switch to another app.
- `SelectionLens`: a nested glass view, a direct child of the main glass content view, moved with a Core Animation position spring.
- `GlassHeightAnimator`: display-link driven. Content is laid out at its final size at once and the glass grows over it.
- `Theme`: every color, font and metric in one value, so a user can restyle the launcher without touching views. `ThemeStore` loads and saves themes as JSON files and tells the panel and the settings window when the theme changes.
- `LauncherSurface`: the panel with its glass, query row, hairline, content area and action bar. Lists, grids, detail panes and forms fill the content area by conforming to `LauncherContentView`.
- `LatencyProbe`: always on. One signpost interval per interaction, never per row.
- `Capture`: ScreenCaptureKit capture of our own windows over synthetic backdrops. It needs no permission and shows real glass. `LauncherUITesting` adds a clip recorder with MP4 and GIF writers and an idle guard that drops a clip the moment the person at the keyboard returns.

### Platform

Live implementations of Kit's service protocols. Carbon hotkeys with conflict checks through `CopySymbolicHotKeys`. The pasteboard client, including paste into the frontmost app. The icon cache with its atlas. Permission checks that never prompt unless the user asked and never block: answers come from a cache refreshed in the background. Frontmost-app tracking and the system context. Text expansion as a pure typing state machine behind a listen-only event tap. Outside the live environment every service is inert: it keeps books and touches nothing on the Mac.

Three rules protect the user from the services themselves. A read guard keeps background reads, such as icons and the app catalog, out of Downloads, other volumes and other apps' data, where a read can raise a system prompt; a generic icon shows instead. It follows symbolic links, and finds them without reading inside a protected place. A path on the data volume, `/System/Volumes/Data/...`, counts as the same path without that part, and any Photos library and the Contacts, Calendars and Reminders data need Full Disk Access. Text expansion ignores and forgets typing in the app's own windows. A paste waits until the panel has given up key focus, and fails with a message if it never does. A pasteboard read that another app's write interrupts is dropped. A paste and a concealed copy stay on this Mac: Universal Clipboard does not carry them. Typed text never carries control characters other than tab and line breaks.

The HTTP service follows a redirect only to the same host unless the request names another rule, and never from https to http. A response says which address answered and whether a redirect was refused. File changes can carry what FSEvents knows: the flags that ask for a rescan or report dropped events, event IDs, and a mark to resume from after a relaunch. iCloud Drive is a protected folder of its own, which Full Disk Access does not count for. Full Disk Access is checked again at launch and on app switches, at most every 10 seconds, so a grant taken away is noticed.

A hotkey that an enabled macOS shortcut holds is marked as a system shortcut. Item and feature hotkeys are refused for it. The launcher hotkey alone may wait for it.

### Host

Host has two halves.

The feature runtime makes each feature, reads its declarations, turns features and commands on and off, binds hotkeys, and runs every command and action through one pipeline: permissions, confirmation, run policy, handler, outcome. It implements `FeatureDirectory` and `ItemPreferences`. A handler keeps running when the panel closes. Once the panel session a run started in has ended, the runtime drops that run's push, pop and close outcomes and shows only a close's HUD.

The panel half turns Kit views into LauncherUI views. It owns the navigation stack, the action panel, in-panel confirmations, forms, toasts, the keyboard model and the scenario runner. It drives root search through `RootSource` and never imports `Root`.

Panel sizing: by default the glass is as tall as the full list, so typing never resizes it. With fit-to-content sizing, a height change caused by typing snaps in the same frame. Only navigation and overlays animate the height.

Closing the panel ends root search's session: sections still loading are cancelled and the page stops showing that it loads. Pages do no work while the panel is hidden. A change signal that arrives then is remembered, and the page reloads once when it is next shown. A detail stream that is already running keeps filling its model and draws nothing.

Questions and feedback:

- A command's declared confirmation and a feature's own `confirm` both show a card inside the panel. One with a suppression key offers Don't ask again, and the stored answer is honored for both kinds.
- A run that lacks a permission shows the permission card. After the user presses its button the run waits up to 300 seconds for the grant, then goes ahead. A newer run that waits on the same permission replaces the older wait, so one grant runs one thing.
- A page without a title takes its command's title.
- A toast's action is the action bar's button and the first entry of the action panel, so the keyboard reaches it.
- In the action panel a universal action whose title the row already offers is left out. The row's own action wins.
- A question for a run that started outside the panel, by a hotkey, a link or a typed keyword, opens the panel, and Cancel closes it again. When a grant has to happen in System Settings, the panel closes first and a HUD says what to allow.
- A command run without a required argument opens a page that asks for it in the search field. A command row's actions get the values typed in its chips.
- A link never runs a command that stays out of deep links. Neither does a hand-off from a run a link started, nor any run in a panel session a link opened; the toast says that opening the launcher yourself runs it.
- A dropdown argument whose value is not one of its options is refused for every launch source, with a toast that names the argument.
- In a panel session a link opened, a destructive confirmation starts on Cancel, so Return cancels until Tab moves to its button, and that button works once the question has been open for a second, as on the page that asks.
- A link in a detail opens http, https and mailto at once. Any other target shows in full in a toast whose Open button opens it.
- Show in Large Type, Command-L, is the host's action for every row and detail that represents text. It closes the panel and shows the text across the screen until any key, any click or a switch to another app. Outside `live` it is recorded.
- A run a link started, or one that starts in a panel session a link opened, gets a pasteboard whose paste only copies, and a failure toast says Copied, Not Pasted. Its context says so with `startedByLink`, whatever its launch source, and AI shows its form before it reads or sends anything.
- A grid that hides titles names the selected cell in the action bar.

Tab accepts, in order: the selected row's completion, the ghost completion, then the user's Tab command. Root search always selects the first row after a keystroke. Text a link typed selects none, and Tab runs no Tab command for it. A pushed list keeps its selection while that row is still visible. In the action panel a command row shows Run, then the command's own row actions, then the host's entries.

Keyboard model:

| Key | Does |
|---|---|
| Return, Command-Return | primary and secondary action |
| Command-K | action panel |
| Command-1 to 9 | run the Nth row |
| Tab, Shift-Tab | accept completion or move between arguments |
| Up, Down, Control-N, Control-P | move selection |
| Command-Up, Command-Down | jump between sections |
| Escape | clear the query, then go back, then dismiss |
| Command-Escape | back to root |
| Delete on an empty query | go back |
| Command-P | filter dropdown |
| Command-Y | Quick Look |
| Command-L | Show in Large Type, for a row or detail that represents text |
| Command-comma | settings |

### Root

Root search is a list like any other to the panel, with a special data source. Root implements `RootSource` and `LearningInspector`, and the two Kit services the engine backs, `UsageService` and `FuzzyIndexService`. It reads features through `FeatureDirectory` and never imports `Host`.

- Empty query: Suggested, then Favorites.
- Typed query: instant answers that claim the top, then engine results, then one section per async provider, then fallbacks. Only the fallbacks that are on show, in the user's order. A fallback starts off unless its feature says otherwise, which the default web searches do.
- An instant provider can say its answer changed. Root asks it again for the query on screen, and the new answer joins as that provider's own section without moving the rows above it.
- Async results only append to their own sections. They never reorder what the user is already looking at. A late row that stands for a file a row above already stands for, such as an app's bundle found by file search, is left out.
- A row you ran that no command or catalog source holds, such as a file from an async provider, is remembered with a display snapshot and joins the synchronous catalog. A file you open often behaves like an app. Rows a catalog source owns are never remembered, so an item its source removed does not come back.
- Suggestion triggers are asked when the context changes, never on the summon path, and chosen by Thompson sampling. At most one trigger row is shown, or two when one is imminent.
- Running an item records the query, the item, the context and how it was reached.

### SettingsUI

A separate SwiftUI window with eight panes: general, with the update switch, an update that waits, the last check and Check Now, appearance with a live theme editor, root search, features with per-command alias, hotkey and enable switch, permissions, learning inspector, advanced, with the commands links may run without asking, and about. Theme edits apply when saved. Onboarding has six steps: welcome, the hotkey, optional features, permissions, a theme, done. In a build that updates itself, the done step has Check for Updates Automatically, which starts on and is stored only when the person finishes. The hotkey step walks the user through turning off Spotlight's shortcut when Spotlight holds the launcher hotkey, with the system's own words for each control, and confirms the moment the combination is free. Optional features lists every feature that is off by default, which is how clipboard history gets switched on. The permissions step shows only what the enabled features need and asks macOS for nothing until the user presses Allow. App tells settings whether the launcher hotkey is bound or waiting through `LauncherHotkeyStatus`. Features contribute panes declaratively.

### Updates

The `Updates` package is the one place that knows Sparkle. The rest of the app sees `KitHosting.UpdateControl`.

- **One case.** Sparkle's updater exists only in the live launcher started from a bundle whose `Info.plist` carries a feed address, `SUFeedURL`, and a public key, `SUPublicEDKey`. `Updates.make(environment:bundle:remindsInMenu:)` decides, and every other run, the scenario, selftest and bench modes, every test and every build without a feed, gets `NoUpdates` and never makes a Sparkle object. `scripts/bundle.sh` writes the feed only for release packaging, so a build from source never offers to replace itself with a release.
- **The feed** is `appcast.xml` attached to the latest GitHub release of `BRAND_REPOSITORY` in `support/brand.env`: `<repository>/releases/latest/download/appcast.xml`. `ProjectLinks.repository` holds the same address, and `scripts/check-brand.sh` fails when they differ. GitHub's latest release skips pre-releases, so no release is marked as one. `make release` writes the appcast, and `make release-publish` uploads it with the zip. The updater's delegate hands Sparkle the address from `Info.plist`, so Sparkle ignores one written into the app's user defaults. The feed is not signed: whoever can publish a release can change what the update window shows, but cannot get code installed. `SECURITY.md` says what that allows. CI's token may only read the repository.
- **The key.** Each update is the release zip signed with an EdDSA key. The public half is `BRAND_UPDATE_PUBLIC_KEY` in `support/brand.env`, which `scripts/info-plist.sh` writes as `SUPublicEDKey`. The private half lives in the owner's login keychain under the account named after the bundle ID, and only `make release` uses it, through Sparkle's `sign_update`. `make release` then checks the signature against the public key with `scripts/update-signature.swift`, which needs no keychain. The dry run signs with a throwaway key it makes in memory. `docs/RELEASING.md` says how to make, back up and import the key, and what a lost key means.
- **Each release follows the last.** Sparkle installs only a higher build number, which is the commit count. `make release` refuses when `HEAD`'s count is not higher than the last release tag's, as after a rewritten history, and when `support/brand.env` names another key than that tag did, unless `UPDATE_KEY_ROTATION=1` says the key was replaced on purpose.
- **What the app sends.** Nothing until the person agrees. `Info.plist` sets `SUEnableAutomaticChecks` to false, so Sparkle never asks its own question. Onboarding's last step and the General pane have the switch. With it on, Sparkle asks for the feed once a day, `SUScheduledCheckInterval`. The request carries Sparkle's user agent, the names and versions of the app and of Sparkle, and nothing else: no system profile key is allowed and no feed parameter is added. Release notes come inside the appcast, so showing them sends nothing. The zip downloads only when the person installs: `Info.plist` sets `SUAllowsAutomaticUpdates` to false, so Sparkle never offers to download and install updates on its own.
- **What the person sees.** A check the person asks for, from the menu or Check Now, shows Sparkle's standard window. While the menu bar item is shown, a scheduled check opens no window and takes no focus: through Sparkle's gentle reminders the update waits, and the menu bar menu leads with an item that names it until the person looks, or the update session ends. While the item is hidden, no menu can remind, and an update nobody sees would keep the session open and stop every later scheduled check. So Sparkle then shows its window as it does for any background app: behind other apps' windows, or in front just after launch. The General pane names a waiting update in both cases, with a Show Update… button beside it.
- **Signing.** `scripts/bundle.sh` copies `Sparkle.framework` from the Updates package's SwiftPM artifact into `Contents/Frameworks` with its links, and the App package's manifest gives the executable the runpath `@executable_path/../Frameworks`. Every build signs the framework and each helper inside it, two XPC services, the Updater app and Autoupdate, with the app's identity, deepest first, with the hardened runtime. Library validation then loads only code with the app's Team ID. Ad hoc code has none, so an ad hoc build also carries `com.apple.security.cs.disable-library-validation`, and a Developer ID release never does. `--version` costs 0.3 ms more with the framework linked, measured as the median of twenty runs.

### Features

Each feature is a package under `Packages/Features`. It depends on Kit, ships its own tests, and is registered by one line in `Packages/App/Sources/SlickApp/Features.swift`.

### App

The executable. `Packages/App/Sources/Slick/main.swift` is one line; everything else is in the `SlickApp` target. App is the only package that imports every other one.

**Composition.** `Assembly` builds the whole launcher for one run environment over one data folder, in this order:

1. `PlatformServices` for the environment. It starts listening to the Mac only in `live`.
2. Kit's `Services` from Platform's, with forwarders for the usage service and the fuzzy index. Root makes those two, but Root needs the feature runtime first, so the forwarders break the cycle.
3. Host's `FeatureRuntime`, with `preferences.json` in `<data>/Features/app.host`.
4. `RootSearch` over the runtime, its preferences, Platform's system context, the settings and the clock. Its engine opens off the main thread. When another engine holds the folder, Root falls back to memory and App says so in the menu bar item, as a HUD and on standard error.
5. The forwarders point at Root. Then the `ThemeStore` over `<data>/Themes` with the stored theme name, the `PanelController` over Root and Platform's icons, the settings window's dependencies, the deep link router and the launcher hotkey.
6. Hooks: the pasteboard closes the panel before a paste, reads clipboard history from the feature that provides it while that feature is on, and text expansion runs its commands through the pipeline with launch `.textExpansion`.

The updater comes from `Updates.make(environment:bundle:remindsInMenu:)` in step 6. See "Updates" above.

`start()` registers the features from `Features.swift`, one line each, activates them and binds the launcher hotkey from `HostSettings.launcherHotkey`, again whenever the setting changes. `shutdown()` unbinds it, deactivates the features, flushes Root, lets the engine go and stops Platform.

**The launcher**, with no arguments: an accessory app with no Dock icon. One copy runs per data folder: the live launcher holds a lock on `launcher.lock` there, which the kernel frees when the process ends, and a second copy asks the first to open its panel and quits. Selftests, benches and scenarios use temporary folders and never take the lock. A menu bar item with a bolt opens the launcher, settings and quit, and follows `HostSettings.showStatusItem`. In a build that updates itself it also has Check for Updates… above Quit, and leads with an item that names an update a scheduled check found. While the item is hidden, Sparkle shows such an update in its own window instead. It appears before the features activate, because it is the only way in while the hotkey waits. Command-comma opens settings. Onboarding shows on the first launch, also before the features activate. Quitting waits for `shutdown()`, for 5 seconds at most. On the first launch only, Root asks App for light priors: the Dock's apps, the running apps and Spotlight use counts for apps in the system's app folders, gathered off the main thread with no prompt.

**The launcher hotkey** is `HostSettings.launcherHotkey`, Command-Space by default. Spotlight holds that combination on a new Mac. While an enabled macOS shortcut holds the combination, the launcher hotkey waits: nothing is bound, no error shows, and onboarding, the General pane and the menu bar menu each say who holds it and offer to open Keyboard settings. The moment the combination is free, App binds it and shows a HUD. A refusal by one of the launcher's own bindings is different: the last working combination stays bound and a failure HUD shows.

**Deep links**, in the scheme from `Kit.Brand`:

| URL | Does |
|---|---|
| `<scheme>://` or `<scheme>://search?q=<text>` | opens the launcher, with the text typed |
| `<scheme>://commands/<feature id>/<command id>?<argument>=<value>` | runs a command, which may open its page |
| `<scheme>://settings`, `<scheme>://settings/<pane>`, `<scheme>://settings/features/<feature id>` | opens settings |

Any web page can fire such a URL. Every part is checked and anything unexpected is refused: other schemes, credentials, ports, fragments, broken escapes, control and direction-override characters, invisible format characters, other characters that draw as nothing, such as the Hangul filler and the braille blank, runs of more than three spaces, empty, `.` or `..` segments, unknown routes, features, commands, panes and arguments, duplicate items and text over 500 characters. A command that sets `allowsDeepLinks` to false is refused before anything is asked, even after Always Allow. A link that opens the launcher types its text but selects no row until the user types, moves the selection or clicks one, so Return, Command-1 to 9 and Tab run nothing the link chose. A command never runs silently. Unless the user chose Always Allow for that command with exactly these arguments, and it still has the title it had then, the panel opens on a page that names it, gives each argument a row and shows every argument in full in a pane beside them, and offers Run, Always Allow and Cancel, with Cancel selected. Typing filters nothing there, so Cancel stays selected, and Command-1 to 9 run no row of it. Run and Always Allow work once the page has been open for a second. The wait starts again when another link replaces the page or the panel opens on it again. A link that arrives while the user works in the panel asks over the page they have open, and Cancel, Back and the run return to it. Allowances are stored under `app.links.allowedCommands` through KitHosting's `LinkAllowances`. The router drops those whose command is gone or renamed, and the Advanced pane lists them with Remove. A panel session a link opened copies instead of pasting.

**Entry points.** Only the launcher runs in `live`. Every other mode runs in its own environment, uses `--data-dir` or a fresh temporary folder that it deletes, and prints a verdict line last.

- `--selftest`: checks the Rust ABI and the bundle ID, then builds the launcher in `selftest` with an in-memory engine, checks that every feature registered and activated with no validator issue outside a short known list, and queries the real `RootSource` for every command and three rows of every catalog source. Shows nothing.
- `--bench [name]`: the real Root and features over synthetic catalogs of 3,000 and 10,000 items. Root's own lines first, then Host's `HostBench` on the real panel. The panel shows in a corner without key status. `name` is `root` or one of Host's benches. `--bench summon-key` summons with key status and runs only when named, because it takes the keyboard for a moment.
- `--scenario <file> [--output <folder>]`: Host's `ScenarioRunner` on the real panel, with the real Root and features against inert services and the Apps feature's synthetic tree. The workspace and HUDs record instead of acting, and settings records what it would open. Scenario files live in `scenarios/`. Besides Host's steps they take `{ "app": { ... } }` steps for what only the app can see or do: the launcher hotkey, deep links, what the workspace launched, what settings opened, aliases, favorites, the last HUD and the private pasteboard. `ScenarioRunTests` runs every file headless and off screen on each `make test-App`. A scenario waits for each feature's own loading before its first step unless the file sets `startsBeforeReady`. Its clock is in UTC and moves only by `setTime`. App steps set the app in front, start a session, select a row by title, wait for a row, set fallbacks, walk onboarding, write made-up files in the run's home folder and hand them to the next open dialog, and open, capture and close the settings window and the onboarding window on a named step. Host's steps click a link a detail shows, and an `expect` step's `largeType` reads the text Large Type showed. The file key `systemApps` shows Apple's own apps from `/System/Applications` with their real icons, and nothing from the user's folders. A `still` step pictures the whole recorded area during a clip, such as the settings window over the wallpaper.
- `--version`: prints the name, the version and the build number, such as `Slick 0.1.0 (412)`, and exits before the app makes any folder, window, menu bar item or hotkey. dyld loads every linked framework before `main`, so a bundle whose framework is missing or wrongly signed fails at once. `scripts/check-release.sh` and CI start bundles this way. It is the one way an agent may start a bundle, and only one a dry run made in a temporary folder.
- `--data-dir <folder>` or `SLICK_DATA_DIR` picks the data folder in any mode.

## Latency rules

Budgets are main-thread CPU time, measured inside the app bundle, where the main thread often runs on efficiency cores:

| Path | Budget |
|---|---|
| Keystroke, all main-thread work | 3 ms p50, 5 ms p99 |
| Engine query inside that | 300 µs p99 at 3,000 items, 1 ms p99 at 10,000 items |
| Root search around the engine query: sections, rows, highlights | 500 µs p99 at 3,000 items, 1.5 ms p99 at 10,000 items, engine included |
| A streamed detail append, coalesced to one per frame | 1.5 ms p50 |
| A live provider's instant path | 100 µs |
| Summon, excluding `makeKey` | 1 ms |
| One-shot interactions: open the action panel, push a page, show a form | 8 ms p99, which is one frame at 120 Hz |
| Idle | no timers except the 4 Hz pasteboard poll, which runs off the main thread, and the two waits below |

Where this stands in November 2026, measured in the joined app with sixteen features registered, at a load of 6 to 8: a root search takes 26 µs p50 and 70 µs p99 over 3,146 items, and 41 µs and 134 µs over 10,146. A keystroke takes 1.3 to 1.4 ms p50 and 4.6 to 4.7 ms p99 from the field editor to the commit, of which drawing the rows and the Core Animation commit are 2.9 to 3.6 ms at p99. That passes the 5 ms budget with little room, and the same bench missed it in earlier runs. A streamed detail append takes 0.98 ms p50. Opening the action panel takes 1.4 to 1.8 ms p50, and pushing a page 1.7 ms. The summoner's own path takes 0.024 ms. With key status, `makeKey` takes 2.5 ms p50 and the glass's key look another 2.4 ms, and first pixels arrive at 26.5 ms p50 and 46.8 ms p99 as the finished look.

The engine budget is for that measurement, inside the app. A stress bench that holds the thread at background priority reads between 120 and 370 µs at p99 over 3,000 items, depending on how fast the efficiency cores run at that moment, so it does not hold 300 µs there.

Two waits may run a timer while the app is idle, and both end by themselves:

- While the launcher hotkey waits behind a macOS shortcut, App reads the system's shortcuts every 2 seconds for 10 minutes, then every 30 seconds. No timer runs once the hotkey is bound.
- While a feature listens for a permission it lacks, Platform's one shared poller checks every second while the app is active or for two minutes after the user pressed a Grant button, and every 10 seconds otherwise. With no listener there is no poller. A feature opens such a stream only while the permission is missing.

Rules that keep it that way:

1. No file, network, XPC or Apple Events call on the main thread inside a keystroke or a summon. `NSWorkspace.icon`, `Bundle(path:)`, `FileManager` and `NSMetadataQuery` all count.
2. The summon path changes visibility and key status and nothing else. Everything the panel shows at summon was prepared at dismiss or on the last context change.
3. No SwiftUI and no `NSTableView` in anything that updates per keystroke.
4. No per-keystroke heap allocation in the engine query path. Reuse buffers.
5. Async work is cancelled when the query changes, by generation counter.
6. Every interactive path carries a `LatencyProbe` interval. `make bench` prints the tables and budget tests fail the build when a budget is blown.

## Glass rules

1. One `NSGlassEffectView` for the panel body, style `.regular`. Never `.clear` for the body.
2. The panel takes real key status. It never fakes `isKeyWindow`. Anything that would need a second key window is drawn inside the panel instead.
3. The window is fixed in size. Only the glass height animates, from a display link, and never because the user typed. Never set `ignoresMouseEvents`, because transparent areas already pass clicks through.
4. The selection lens is nested directly in the glass content view and moves by position spring. It does not go inside an `NSGlassEffectContainerView`.
5. Result text is drawn with Core Text, so it is not vibrant. The theme must reach a contrast ratio of 4.5 to 1 for titles and 3 to 1 for secondary text over busy, white and dark backdrops in both appearances. An appearance tint on the glass does most of that work, and only a pure white or black tint does it: a colored light tint, even a faint one, costs up to 1.3 of title contrast over a dark backdrop. Built-in themes keep the white light tint and put their color in the accent and the lens. Changes to the theme are checked against the capture matrix.
6. Labels that are real `NSTextField`s, such as the query field, keep vibrancy on. Do not toggle it at runtime.
7. Under Reduce Transparency the tint is dropped and the system's opaque glass is used. Under Reduce Motion nothing animates.
8. `effectIsInteractive` is for small controls on macOS 27. It stays off for the body.

## Concurrency

- Swift tools version 6.2 or later, Swift 6 language mode.
- UI, host and feature packages use `defaultIsolation(MainActor.self)`.
- Upcoming features on everywhere: `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `MemberImportVisibility`, `ExistentialAny`.
- Background work is `@concurrent nonisolated func`. Pure logic is `nonisolated`.
- The engine handle is a checked `Sendable` class over a Rust `RwLock`.
- Tests use Swift Testing.

## Storage and privacy

- Data lives in `~/Library/Application Support/Slick`. `SLICK_DATA_DIR` or `--data-dir` overrides it.
- The data folder is made with mode 0700 in every mode, and a folder with a wider mode is tightened at launch.
- Settings live in `UserDefaults` behind typed keys.
- Clipboard history uses SQLite in WAL mode. Small collections such as snippets and quicklinks are JSON files written atomically.
- Every SQLite database overwrites what it deletes. A clipboard delete rewrites the full-text index and empties the write-ahead log, and the clipboard folder is left out of backups.
- Slick makes no network request unless a feature the user invoked needs one: currency rates, a web search, an AI provider the user configured. The one other request is the update check of a release build, and only once the person turned it on: once a day, to the GitHub release feed, carrying nothing but the versions of Slick and Sparkle.
- There is no telemetry. The learning inspector in settings shows what was learned and can delete a row, forget an item, pause learning or erase everything.
- Concealed, transient and auto-generated pasteboard items are never stored.

## Working on a live desktop

Developers and agents build and test Slick on the machine they are using. These rules protect that machine.

1. Run the launcher only through `--selftest`, `--bench` or `--scenario` unless the person at the keyboard asked for the real app. `--version` starts nothing and may run any time.
2. In those modes hardware key events are ignored, side effects go to inert services or fakes, and data lives in a temporary directory. A scenario can never sleep the Mac, empty the Trash, move someone's windows or paste into their document.
3. Tests never read the general pasteboard. They use a private named pasteboard.
4. Tests never call an API that can raise a permission prompt. Use the fake permission center.
5. Window management tests move only windows the test created. Accessibility works on your own windows without a grant.
6. File index tests walk a synthetic temporary tree, never the home folder.
7. Tests make no network requests.
8. Anything shown on screen during a test is brief. Scenarios take key status only when a step needs the key glass look, and for well under a second.
9. No test data, fixture or log contains real file names, clipboard contents or contacts.
10. Tests never hand a made-up bundle to LaunchServices. Asking the system for a bundle's localized name, its display name or its icon registers that bundle in the user's LaunchServices database, with a synchronous call to a daemon that can stall. The Apps feature therefore names apps from their own property lists. A copy launched from a scratch folder, and build's copy while `make install`'s copy exists, is unregistered afterwards with `lsregister -u`, so the system knows one launcher.

## Build

`make help` prints every target. They are defined in the `Makefile` and in `mk/*.mk`, one file per area.

```
make bootstrap               # check toolchains, build the Rust core, resolve packages
make core                    # rebuild the staticlib and header
make app                     # build and bundle build/Slick.app; CONFIG=debug for a debug build
make run                     # build, then launch through LaunchServices, for people only
make selftest                # build, then run --selftest directly and through LaunchServices
make test                    # every Rust and Swift test
make test-rust               # every Rust test, ended after RUST_TEST_TIMEOUT seconds
make test-scripts            # the install, showcase, bundle and time limit scripts, in a temporary folder
make test-<Pkg>              # one package, such as make test-App
make bench                   # latency tables from the app bundle; NAME=<bench> picks one
make scenario S=<file>       # one scenario through LaunchServices
make scenarios               # every scenario in scenarios/
make app-size                # the bundle's size, its largest parts and the dSYM
make lint                    # rustfmt, clippy, swift format, manifest, brand and LaunchServices checks
make fmt                     # format Rust and Swift sources in place
make xcode                   # generate the optional Xcode project with XcodeGen
make clean                   # remove every build output
make bench-core              # the Rust engine bench, the feature index bench, then the CoreBridge bench
make sim                     # the ranking simulator
make ui-shots                # LauncherUI capture matrix, contact sheets and contrast table
make ui-components           # LauncherUI component sheets
make ui-bench                # LauncherUI latency tables, measured as an app
make ui-type                 # LauncherUI synthetic typing through the real keystroke path
make ui-accessibility        # LauncherUI panel read through the accessibility API
make ui-legibility           # LauncherUI contrast over a sweep of glass tints
make test-LauncherUI-budget  # LauncherUI budget tests in a release build
make ui-showcase             # regenerate the site's product pictures
make ui-record               # LauncherUI clip in motion, then MP4 and GIF copies
make media                   # record every storyboard in scenarios/media over Apple's own apps and publish to site/media
make install                 # the release app into /Applications or INSTALL_DIR, for people only
make uninstall               # remove it
make release-dry-run         # the release pipeline signed ad hoc in a temporary folder, every artifact checked
make update-key              # make the key that signs updates in the login keychain, for people only
```

Release builds move their symbols into `build/Slick.app.dSYM` beside the bundle and strip the executable. Debug builds keep the symbols in place. `STRIP=0` or `STRIP=1` overrides either. With sixteen features the bundle is 16 MB: the executable is 12.4 MB, about 0.9 MB of it the Rust core, and the compiled icon, `Assets.car`, is 3.7 MB. The dSYM is 42 MB.

`make selftest`, `make bench` and `make scenario` run the app through LaunchServices with `scripts/launch.sh`, which waits for the mode's verdict line, because LaunchServices does not hand back the exit status. Scenario results and captures go to `build/scenarios/<name>`.

Requirements: macOS 27 with Xcode 27 to build, Rust stable. The deployment target is macOS 26, and macOS 27 APIs sit behind availability checks. Slick is developed and tested on macOS 27. macOS 26 is untested.

Development builds are signed with your Apple Development identity when you have one, so permission grants survive a rebuild. Ad hoc builds lose their grants on every rebuild.
