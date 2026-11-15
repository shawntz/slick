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
App         ->  everything
Kit         ->  nothing
LauncherUI  ->  nothing
CoreBridge  ->  nothing in Swift, links libslick_ffi.a
```

- A feature never imports another feature, `Host`, `Root`, `Platform` or `App`. Features talk to each other through Kit contracts.
- `Host`, `Root`, `Platform` and `SettingsUI` never import each other. They meet through the protocols in `KitHosting`, and `App` connects them. A feature never imports `KitHosting`.
- Only `CoreBridge` sees the C header. Only `slick-ffi` exports symbols.
- `Kit` and `LauncherUI` stay small, because every package that depends on them compiles its own copy.
- New code goes in a new file. Shared files that many people touch, such as the feature list in `App`, change one line at a time.

One package per module is deliberate. A syntax error in one feature cannot stop another feature's tests, and two people building different packages never wait on the same lock.

## The core

### Matching

`slick-match` holds each corpus in a flat structure-of-arrays arena of case-folded, diacritic-folded bytes. Per item it stores a 64-bit character-presence mask, a word-initials mask and a word-start bitmap. A query runs mask prefilter, then NEON occurrence bitmaps, then tier classification, then top-k with a running threshold. A session narrows: when the query grows, only the previous match set is re-scored. Highlight ranges are computed for visible rows only and come back as UTF-16 offsets.

Text tiers, strongest first:

| Tier | Meaning | Example |
|---|---|---|
| exact | folded title equals folded query | `safari` and Safari |
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
- The caller owns every buffer. The query path allocates nothing.
- Every exported function returns an `i32` status and wraps its body in `catch_unwind`. A panic comes back as a status code, never as an abort.
- `slick_abi_version()` is checked at launch.
- One Rust module per area in `slick-ffi`: `engine.rs`, `index.rs`, `calc.rs`, `files.rs`. The header is generated by cbindgen, committed, and checked for drift in CI.
- `scripts/build-rust.sh` installs the staticlib with an atomic rename, so a Swift link never sees a half-written file.

## Swift packages

### Kit

Kit is the vocabulary every feature is written in. It has no dependencies. Features describe; the host draws.

- **Values.** `ItemID`, `Row`, `ListSection`, `Payload`, `Icon`, `Accessory`, `KeyCombo`, `Detail`, `Toast`, `HUD`, `Selection`. All `Sendable`. Rows are plain data, built on any thread. A row carries its item in memory as a `Payload`, says what root search keeps (`memory`), when it expires, what it stands for (`represents`, which brings every feature's universal actions to it), match highlights and an in-tier `rankHint`.
- **Behavior.** `Action` and `ActionOutcome`, `Command` with up to three inline arguments, a confirmation and row actions. Actions come from the source that made the row, never from the row. The host checks `requires`, asks the confirmation, runs handlers under a `RunPolicy` (serial per feature by default), shows thrown errors as failure toasts, draws toasts as HUDs while the panel is closed, and does not cancel a handler when the panel closes. Outcomes close, push, replace, pop, return to root with a query, run another command, or ask the host to run its permission card.
- **Features.** A `Feature` declares a manifest, commands, catalog sources, live providers, suggestion triggers, universal actions, a settings pane, hotkey presets, a status for settings and the services it provides to other features. The host reads declarations at registration and after `declarationChanges`; sources and providers are stored objects.
- **Root search inputs.** A catalog source pushes rows that the engine matches synchronously. A live provider answers per keystroke, either instantly on the main thread within 100 µs, or asynchronously with cancellation. A suggestion trigger offers situational rows. Each names a namespace that routes remembered rows back to it; one object may hold one namespace in several roles. List, catalog and suggestion sources share `RowSource`: a `ChangeSignal` and the settings that reload them.
- **Views.** A command can push a list, a grid, a detail or a form. Lists filter in the host (with section visibility and rank hints) or in the source (with paging and highlights), and may replace their filter dropdown or show a notice. Detail sources stream updates and build actions from the detail shown.
- **Services.** Everything with a side effect sits behind a protocol on `FeatureContext`: pasteboard, workspace, hotkeys, permissions (status and changes), process runner, HTTP, storage paths, settings, secrets, clock, usage tracking, fuzzy indexes, selection, file watching, file dialogs, text expansion. Async requirements that do work are `@concurrent`. A service only one feature uses is named by a `FeatureServiceKey`, which picks the live or isolated implementation per run environment and takes a test override. Each Kit service has a fake in `KitTesting`, which also holds `FeatureHarness`; `settle()` waits until a feature's background loops have handled what the fakes sent. Optional weight lives in separate targets: `KitStorage` (SQLite with cancellable queries, atomic JSON files) and `KitTemplates` (placeholders).
- **Run environment.** `live`, `scenario`, `selftest`, `bench`. Outside `live`, side effects go to fakes and features get the isolated implementation of their own services.

Exact signatures live in the code. `docs/FEATURES.md` walks through writing a feature.

**KitHosting** is a separate target for the contracts between the app's own packages. It depends on Kit only and has no default isolation; the protocols the UI touches are `@MainActor`. Features never import it.

- `FeatureDirectory`: every registered feature as a `FeatureEntry` in registration order, on or off, with its manifest, context, declarations and `CommandEntry` list, plus a change signal. Host's runtime implements it. Root and SettingsUI read it.
- `ItemPreferences`: what the user attached to items, which is aliases, hotkeys, favorites and feature and command switches. Setting a hotkey binds it, takes it over from another item, and throws `HotkeyError` for a conflict that cannot be overridden. Host implements it. Root reads aliases and favorites. SettingsUI edits all of it.
- `RootSource`: root search as the panel drives it. `begin()` returns the prepared empty state on the summon path, `update(query:)` runs inside the keystroke, `snapshot` and `changes` carry sections that arrive late, and `end()` cancels. A `RootSnapshot` holds `RootSection`s, a `RootCompletion`, a loading flag, an empty state and a revision. It also gives highlights for rows that scroll into view, a row's feature, a row by ID, and run and forget records. It returns no actions for command rows, because Host runs commands itself, and the section kind sets the launch source. Root implements it. Host drives it.
- `LearningInspector`: what the engine learned, with a summary, top items, learned queries, forget, pause and erase. Root implements it. SettingsUI shows it.
- `IconProvider`: icon lookups that never read the disk or decode on the main thread. Nil means not ready; the provider loads off the main thread and signals. Platform implements it. Host and SettingsUI draw with it.
- `SystemContextService`: the frontmost app, power, displays, audio route and Focus, with a stream of changes and one of session starts. Platform implements it. Root feeds the engine with it.
- `LoginItemControl`: whether the app opens at login. Platform implements it. SettingsUI shows it.
- `HostSettings`: the typed keys of the general settings that more than one package reads, stored under the `app.general` namespace.

`KitHostingTesting` holds a fake for each, and `FakeFeatureDirectory.register` and `FeatureEntry.make` build entries from real features over `FakeServices`, so Root and SettingsUI tests need no Host.

### LauncherUI

LauncherUI draws. It knows nothing about features, the engine or Kit. It takes display structs with resolved text, images and highlight ranges, and it reports key and pointer events upward.

- `GlassPanel`: borderless non-activating panel, `canBecomeKey` true, `canBecomeMain` false, fixed size with transparent insets, one `NSGlassEffectView` with corner radius 26.
- `Summoner`: pre-warms at launch, keeps the panel ordered in, shows by flipping root-layer opacity inside one transaction, then calls `makeKey`. `orderFront` stays available behind a setting.
- `QueryField`: `NSTextField` with a tuned TextKit 1 field editor, ghost completion and inline argument chips. The field editor stays installed. Nothing calls `makeFirstResponder` on the summon path.
- `ResultListView`: one view that draws every visible row with Core Text, diffs per row, and builds accessibility elements on demand.
- `GridView`, `DetailPane` (beside the list in `ListDetailView`), `FormView` and `EmptyStateView` fill the content area. `ActionCardView`, `ConfirmCardView` and `DropdownMenuView` are `PanelOverlay`s that `LauncherSurface.present(_:)` draws inside the panel. `ActionBar` shows toasts and `KeycapView` shortcuts; `HUDWindow` confirms an action after the panel closes.
- `SelectionLens`: a nested glass view, a direct child of the main glass content view, moved with a Core Animation position spring.
- `GlassHeightAnimator`: display-link driven. Content is laid out at its final size at once and the glass grows over it.
- `Theme`: every color, font and metric in one value, so a user can restyle the launcher without touching views. `ThemeStore` loads and saves themes as JSON files and tells the panel and the settings window when the theme changes.
- `LauncherSurface`: the panel with its glass, query row, hairline, content area and action bar. Lists, grids, detail panes and forms fill the content area by conforming to `LauncherContentView`.
- `LatencyProbe`: always on. One signpost interval per interaction, never per row.
- `Capture`: ScreenCaptureKit capture of our own windows over synthetic backdrops. It needs no permission and shows real glass.

### Platform

Live implementations of Kit's service protocols. Carbon hotkeys with conflict checks through `CopySymbolicHotKeys`. The pasteboard client, including paste into the frontmost app. The icon cache with its atlas. Permission checks that never prompt unless the user asked and never block: answers come from a cache refreshed in the background. Frontmost-app tracking and the system context. Text expansion as a pure typing state machine behind a listen-only event tap. Outside the live environment every service is inert: it keeps books and touches nothing on the Mac.

### Host

Host has two halves.

The feature runtime makes each feature, reads its declarations, turns features and commands on and off, binds hotkeys, and runs every command and action through one pipeline: permissions, confirmation, run policy, handler, outcome. It implements `FeatureDirectory` and `ItemPreferences`. A handler keeps running when the panel closes. Once the panel session a run started in has ended, the runtime drops that run's push, pop and close outcomes and shows only a close's HUD.

The panel half turns Kit views into LauncherUI views. It owns the navigation stack, the action panel, in-panel confirmations, forms, toasts, the keyboard model and the scenario runner. It drives root search through `RootSource` and never imports `Root`.

Panel sizing: by default the glass is as tall as the full list, so typing never resizes it. With fit-to-content sizing, a height change caused by typing snaps in the same frame. Only navigation and overlays animate the height.

Pages do no work while the panel is hidden. A change signal that arrives then is remembered, and the page reloads once when it is next shown.

Tab accepts, in order: the selected row's completion, the ghost completion, then the user's Tab command. Root search always selects the first row after a keystroke. A pushed list keeps its selection while that row is still visible. In the action panel a command row shows Run, then the command's own row actions, then the host's entries.

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
| Command-comma | settings |

### Root

Root search is a list like any other to the panel, with a special data source. Root implements `RootSource` and `LearningInspector`, and the two Kit services the engine backs, `UsageService` and `FuzzyIndexService`. It reads features through `FeatureDirectory` and never imports `Host`.

- Empty query: Suggested, then Favorites.
- Typed query: instant answers that claim the top, then engine results, then one section per async provider, then fallbacks.
- Async results only append to their own sections. They never reorder what the user is already looking at.
- A row you ran that no command or catalog source holds, such as a file from an async provider, is remembered with a display snapshot and joins the synchronous catalog. A file you open often behaves like an app. Rows a catalog source owns are never remembered, so an item its source removed does not come back.
- Suggestion triggers are asked when the context changes, never on the summon path, and chosen by Thompson sampling. At most one trigger row is shown, or two when one is imminent.
- Running an item records the query, the item, the context and how it was reached.

### SettingsUI

A separate SwiftUI window with eight panes: general, appearance with a live theme editor, root search, features with per-command alias, hotkey and enable switch, permissions, learning inspector, advanced and about. Theme edits apply when saved. Onboarding covers the hotkey and permissions. Features contribute panes declaratively.

### Features

Each feature is a package under `Packages/Features`. It depends on Kit, ships its own tests, and is registered by one line in `Packages/App/Sources/SlickApp/Features.swift`.

### App

The executable. It builds the service container for the run environment, creates the engine, registers features, installs the status item and handles `slick://` deeplinks.

Entry points:

- no arguments: the launcher
- `--selftest`: start, exercise the engine and every feature's registration, exit
- `--bench [name]`: latency tables, measured inside the app bundle
- `--scenario <file>`: scripted UI run with captures and assertions

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
| Idle | no timers except the 4 Hz pasteboard poll, which runs off the main thread |

Where this stands in November 2026, measured with the main thread held to background priority, the slowest case: the engine query takes 316 µs p99 at 3,000 items against 300, and 972 µs at 10,000 against 1 ms. At normal priority both are about four times faster. From the field editor's change callback to the commit, the panel takes 1.4 to 1.9 ms p50 and 2.6 to 3.1 ms p99. The field editor's own work before that callback adds about 2 ms, so the whole keystroke is still over its 3 ms median budget. Replacing the field editor with a Core Text input is the planned fix. A typical root catalog holds about 3,000 items.

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
5. Result text is drawn with Core Text, so it is not vibrant. The theme must reach a contrast ratio of 4.5 to 1 for titles and 3 to 1 for secondary text over busy, white and dark backdrops in both appearances. An appearance tint on the glass does most of that work. Changes to the theme are checked against the capture matrix.
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
- Settings live in `UserDefaults` behind typed keys.
- Clipboard history uses SQLite in WAL mode. Small collections such as snippets and quicklinks are JSON files written atomically.
- Slick makes no network request unless a feature the user invoked needs one: currency rates, a web search, an AI provider the user configured.
- There is no telemetry. The learning inspector in settings shows what was learned and can delete a row, forget an item, pause learning or erase everything.
- Concealed, transient and auto-generated pasteboard items are never stored.

## Working on a live desktop

Developers and agents build and test Slick on the machine they are using. These rules protect that machine.

1. Run the launcher only through `--selftest`, `--bench` or `--scenario` unless the person at the keyboard asked for the real app.
2. In those modes hardware key events are ignored, side effects go to inert services or fakes, and data lives in a temporary directory. A scenario can never sleep the Mac, empty the Trash, move someone's windows or paste into their document.
3. Tests never read the general pasteboard. They use a private named pasteboard.
4. Tests never call an API that can raise a permission prompt. Use the fake permission center.
5. Window management tests move only windows the test created. Accessibility works on your own windows without a grant.
6. File index tests walk a synthetic temporary tree, never the home folder.
7. Tests make no network requests.
8. Anything shown on screen during a test is brief. Scenarios take key status only when a step needs the key glass look, and for well under a second.
9. No test data, fixture or log contains real file names, clipboard contents or contacts.

## Build

```
make bootstrap     # check toolchains, build the Rust core, resolve packages
make core          # rebuild the staticlib and header
make app           # build and bundle build/Slick.app
make run           # build, then launch through LaunchServices
make test          # every Rust and Swift test
make test-<Pkg>    # one package
make bench         # latency tables from the app bundle
make scenario S=<file>
make lint fmt
```

Requirements: macOS 27 with Xcode 27 to build, Rust stable. The deployment target is macOS 26, and macOS 27 APIs sit behind availability checks. Slick is developed and tested on macOS 27. macOS 26 is untested.

Development builds are signed with your Apple Development identity when you have one, so permission grants survive a rebuild. Ad hoc builds lose their grants on every rebuild.
