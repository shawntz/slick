# Writing a feature

A feature is one Swift package under `Packages/Features/<Name>` that depends on Kit. It describes commands, rows, pages and settings as data. The host draws them, owns the keyboard, and calls back into the feature when the user acts. Every side effect goes through a service on the feature's context, so the same code runs against the real Mac in the app and against fakes in tests.

This guide is enough to write one. It starts with three complete examples, from a dozen lines to a full feature, then covers each part of Kit, the rules that keep Slick fast, testing, and a recipe for each of the large built-in features.

The examples compile and run. They live in `Packages/Kit/Tests/KitTests/Examples`, and the sketches mentioned under "Recipes" live in `Packages/Kit/Tests/KitTests/Capabilities`. Read them next to this page.

## Setting up the package

```swift
// swift-tools-version: 6.2
// Emoji: an emoji grid with skin tones and recents.
import PackageDescription

// Shared settings. Keep this block identical in every Package.swift: scripts/check-manifests.sh
// fails the lint when one drifts.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

// UI, host and feature code is @MainActor unless marked nonisolated or @concurrent.
let mainActorSettings = swiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Emoji",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Emoji", targets: ["Emoji"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(name: "Emoji", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "EmojiTests",
            dependencies: ["Emoji", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
```

Kit is split so a feature compiles only what it imports:

| Product | What it holds | Import it when |
|---|---|---|
| `Kit` | values, feature and page protocols, services, standard actions, text stream helpers | always |
| `KitStorage` | `SQLiteDatabase` and `JSONFileStore` | you keep data on disk |
| `KitTemplates` | the `{placeholder}` engine | you render snippets, quicklinks or prompts |
| `KitTesting` | a fake for every service and `FeatureHarness` | in the test target only |

Make the feature class `public`, and with it `init(context:)`, `manifest` and every `Feature` member the class implements: Swift requires a public class's protocol witnesses to be public. The app lists features in one place; adding yours is a one-line change there plus the package dependency in `Packages/App/Package.swift`.

Build and test from your package only: `scripts/swiftpm.sh Packages/Features/Emoji test`, or `make test-Emoji`.

## Example 1: copy a UUID

The smallest useful feature has one command and no view.

```swift
import Foundation
import Kit

final class UUIDFeature: Feature {
    static let manifest = FeatureManifest(id: "uuid", name: "UUID", icon: .symbol("number"))

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "copy-uuid", title: "Copy UUID", icon: .symbol("doc.on.doc")) { context in
                await context.pasteboard.copy(UUID().uuidString)
                return .close(hud: "Copied UUID")
            }
        ]
    }
}
```

The command appears in root search as `cmd:uuid.copy-uuid`. Its closure runs on the main actor, copies through the pasteboard service, and returns an `ActionOutcome`: close the panel and show a HUD. The user can give it an alias or a hotkey in settings without the feature doing anything.

The test builds the feature over fakes and runs the command:

```swift
@Test func copiesAUUIDAndCloses() async throws {
    let harness = FeatureHarness(UUIDFeature.self)
    #expect(harness.issues.isEmpty)
    try await harness.run("copy-uuid")
    let copied = try #require(harness.fakes.pasteboard.copiedTexts.first)
    #expect(UUID(uuidString: copied) != nil)
    #expect(harness.huds == ["Copied UUID"])
}
```

`harness.issues` runs the same checks the host runs at registration, plus checks on every action list and form the harness handed out. Expect it to be empty in every feature's tests.

## Example 2: a searchable list over static data

A command can push a page. This one pushes a list of HTTP status codes in sections, with a detail pane and two actions. The full file is `Examples/HTTPStatusFeature.swift`.

```swift
Command(id: "search", title: "Search HTTP Status Codes", icon: .symbol("magnifyingglass")) { _ in
    .push(.list(ListPage(HTTPStatusList(), searchPlaceholder: "Search status codes", showsDetail: true)))
}
```

The page's data comes from a `ListSource`:

```swift
final class HTTPStatusList: ListSource {
    func load(_ request: ListRequest) async throws -> ListResult {
        // One section per class, "2xx", "3xx" and so on, every row at once.
    }

    func actions(for row: Row) -> [Action] {
        var actions = [Action.copy(row.id.key, title: "Copy Code")]
        if let url = URL(string: "https://httpwg.org/specs/rfc9110.html#status.\(row.id.key)") {
            actions.append(.open(url, title: "Open Specification", shortcut: .open))
        }
        return actions
    }

    func detail(for row: Row) async throws -> Detail? {
        // Markdown for the selected status.
    }
}
```

Three things to notice.

The source never sees the query. Its filtering is `.host`, the default, so the host loads the rows once, builds a fuzzy index over every title and keyword off the main thread, and filters on each keystroke without calling the source. This is the fast path, and it handles 50,000 rows.

Rows hold data only. The source makes their actions when the host asks, from the row's ID. `Row.keywords` holds the status meaning, so typing "rate limited" finds 429.

Return runs the first action. `Action.copy` and `Action.open` are standard actions with the usual titles, icons and shortcuts.

For a page over rows you already have, skip the class: `ListPage(sections: sections) { row in actions }`.

The test types queries and acts on rows:

```swift
try await harness.run("search")
try await harness.setQuery("not found")
#expect(harness.rows.map(\.title) == ["404 Not Found"])
#expect(harness.fakes.fuzzyIndex.builtIndexSizes == [HTTPStatusList.statuses.count])
try harness.select(title: "404 Not Found")
try await harness.performPrimary()
#expect(harness.fakes.pasteboard.copiedTexts == ["404"])
```

## Example 3: bookmarks, a full feature

`Examples/BookmarksFeature.swift` has most of what real features use. It is about 270 lines. These are its parts.

**Stored data.** Bookmarks are a JSON file in the feature's data folder, written atomically by `JSONFileStore` from `KitStorage`. Storage paths touch nothing, so the store is made in `init`; the folder appears on the first save. The stored type is `nonisolated`, so the store's actor can encode it off the main thread. The feature loads in `activate()` and saves after each change.

```swift
nonisolated struct Bookmark: Codable, Hashable, Sendable { ... }

store = JSONFileStore(url: context.storage.dataFile("bookmarks.json"))

func activate() async {
    bookmarks = try await store.load(default: [])
    changes.send()
}
```

**A change signal.** `let changes = ChangeSignal()` is sent after every save. The list page and root search listen to it through `changes`, and `Feature.declarationChanges` tells the host to read the commands again. An action that saves needs no `context.reload()`: the signal reloads the page.

**A form.** "Add Bookmark" pushes a `FormPage`. The host checks required fields, then `validate`, then calls `submit`, which saves and returns `.pop`. `validate` returns a `FieldError` with the range of a broken placeholder, so the field can select it.

**A list with sections, a filter and an empty state.** "Pinned" and "Bookmarks" sections, a dropdown with "All" and "Pinned" (the selected option arrives as `ListRequest.filter`), and an empty state that offers "Add Bookmark". The list declares `reloadsOnSettings`, so an open list follows the sort order the user picks in settings.

**Root search entries.** The same `BookmarkList` is a `CatalogSource` with the namespace `bookmark`, so every bookmark is searchable from root and ranked with apps and commands. Each row `represents` its link, so every feature's actions for links are offered on it too.

**Actions that work after a relaunch.** Root remembers rows the user runs and hands them back later, rebuilt from a snapshot. `actions(for:)` looks the bookmark up by `row.id.key` and needs nothing else.

**Commands with inline arguments and row actions.** A bookmark whose link has `{argument name="query"}` becomes its own command, so its argument appears as a field in the search bar; `template.commandArguments` makes the fields. Running it renders the link with `KitTemplates` in the `.url` style, which percent-encodes the value. `.withRowActions { ... }` gives the command's row in root search Copy Link, Pin and Delete.

**A fallback.** The search command declares `Fallback { "Search Bookmarks for \"\($0)\"" }`. When root search finds nothing, it can offer this command; the typed text arrives as `context.query` and in the first argument. The command opens the list with `initialQuery` set.

**A universal action.** "Save as Bookmark" is offered for a URL selected in any app, and for any row that stands for a URL.

**A permission for one action.** "Paste Link" needs Accessibility. The action declares `requires: [.accessibility]` and the manifest gives the reason. When the permission is missing, the host shows the reason and a Grant button instead of running the action. Nothing prompts until the user presses Grant.

**Settings.** Two typed keys in a `nonisolated enum`, and a pane:

```swift
nonisolated enum BookmarkSettings {
    static let pinnedFirst = SettingKey("pinnedFirst", default: true)
    static let order = SettingKey("order", default: BookmarkOrder.name)
}

var settingsPane: SettingsPane? {
    SettingsPane(items: [
        .toggle("Show pinned bookmarks first", key: BookmarkSettings.pinnedFirst),
        .picker("Sort by", key: BookmarkSettings.order) { $0.title },
    ])
}
```

Its tests in `ExampleFeatureTests.swift` cover each part: the form's validation, the file on disk, sections and the filter, settings reordering an open list, the confirmation before delete, the permission flow, argument commands and their row actions, the fallback, a remembered row after a simulated relaunch, the universal action and the change signals.

## Rows and identity

`Row` is a plain `Sendable` value: `id`, `title`, `subtitle`, `icon`, `accessories`, `keywords`, `payload`, `completion`, `quickLookURL`, `alternates`, `titleHighlights`, `rankHint`, `memory`, `expires` and `represents`. Build rows on any thread, in any number.

`ItemID` is a namespace and a key, `namespace:key`. Pick a namespace for your rows, usually your feature ID, and keep keys stable across launches: learning, favorites and remembered rows depend on them. `cmd` and `app` belong to root search. The engine sees only `engineKey`, the 64-bit FNV-1a hash of the ID's UTF-8 bytes, which Kit computes once per ID. The Rust core uses the same hash; `ItemIDTests` holds the shared test vectors.

`Payload` carries what the source needs for the row's actions. `Payload(item)` keeps any `Codable`, `Hashable`, `Sendable` value in memory, and `row.payload?.decode(Item.self)` hands it back by a cast, so a list can carry its items with no side dictionary and no JSON. The value is encoded only when root search remembers the row, and after a relaunch `decode` reads that JSON. So `actions(for:)` must still work from the ID and payload alone, and a payload should stay under 1 KB. A plain string, `Payload("...")`, is enough when the key does not say it all.

`completion` is the text Tab puts in the search field: a folder path to descend into, or a calculator answer. Tab uses the selected row's completion when it has one, and the user's Tab command otherwise.

`alternates` change a row's subtitle or icon while modifiers are held. Pair each with an action whose shortcut is Return plus the same modifiers, as `ScriptSketch.swift` does for Script Filter `mods`.

`titleHighlights` are the matched ranges of the title in UTF-16 offsets, for rows the host does not filter: custom-filtered lists and async providers. Host filtering computes its own.

`rankHint` orders rows inside one match tier under host filtering, higher first. Use it for recency, pins or your own order; a weaker tier never outranks a stronger one.

`memory` says what root search keeps after the user runs the row: `.remember` (a snapshot joins the catalog), `.learnOnly`, or `.never` for answers to one query and one-off occurrences. `expires` drops a catalog row when, say, its meeting has ended.

`represents` is the text, URL or files the row stands for. The host then offers every feature's universal actions for it in the action panel, as it does for a selection in another app.

`Icon` is a description, never an image: an SF Symbol, a glyph, an app by bundle ID, a file's icon by path, a type's icon, a local image file, a color swatch, a favicon, a remote `https` image, or a light and dark pair. The host resolves icons from its atlas or loads them off the main thread.

## Actions and outcomes

An `Action` has a title, an optional icon, shortcut, section, style, `Confirmation`, required permissions, an optional `requiresCommand`, a `RunPolicy`, and either a handler or a submenu loader. Handlers run on the main actor and receive an `ActionContext`.

`ActionContext` gives the action every member of the feature's context (`context.pasteboard`, `context.usage`, `context.secrets` and so on), the query, the arguments, how it was launched (`launch`) and the row. It also reaches the panel: `showToast`, `reload`, `setQuery`, `quickLook`, `share`, `confirm`, `dismiss`, and `requestPermission`, which only an action may call because only an action follows something the user did.

A handler returns an `ActionOutcome`:

| Outcome | Does |
|---|---|
| `.close(hud:)` | closes the panel, then shows the HUD if given; `HUD.failure(_:)` for a failure |
| `.keepOpen` | stays; pair with `showToast(_:)` |
| `.push(page)` | pushes a page |
| `.replace(page)` | replaces the top page, so Back skips it |
| `.pop`, `.popToRoot` | goes back |
| `.showRoot(query:)` | goes back to root search with the text in the field, as "Use Again" does |
| `.run(id, arguments:)` | runs another command, possibly another feature's |
| `.needsPermission(p)` | the handler found a permission missing; the host shows its card and runs again after a grant |

What the host does around a handler:

- **Feedback.** `showToast` draws in the panel while it is visible and as a HUD when it is not: after `dismiss()`, or for a command started by a hotkey. A later toast replaces the current one. Keep the returned `ToastHandle` to turn a progress toast into a result or dismiss it.
- **Errors.** A thrown error shows a failure toast, or a HUD when the panel is closed, titled by the error's `LocalizedError.errorDescription`. Throw `ActionFailure("Title", message:)` for your own words. `CancellationError` shows nothing.
- **Long work.** Closing the panel does not cancel a running handler, so a script or a download finishes and reports. Call `dismiss()` first to close the panel at once, as a silent script does. Turning the feature off cancels its handlers.
- **Order.** Runs are `.serial` by default: a second press waits for the feature's earlier serial runs, so read-modify-write state such as cycling a window's size stays right. `.dropWhileRunning` ignores a second start of the same action; `.concurrent` runs at once, for long independent work.

Return runs the first action. Command-Return runs the action whose shortcut is `.secondaryAction`, or else the second action unless it declares a shortcut of its own, so an Option-Return modifier action in second place is not also Command-Return. `[Action].primary` and `.secondary` apply this rule.

Standard actions, all adjustable with `with(id:)`, `with(title:)`, `with(shortcut:)` and `with(section:)`:

| Factory | Shortcut | Notes |
|---|---|---|
| `.open(url)` or `.open(urls)` | | URLs and files |
| `.openWith(url)`, `.openWith(urls)`, `.openWith(resolving:)` | Option-Command-O | submenu of apps; `resolving` renders the link when the submenu opens |
| `.reveal(urls)` | Shift-Command-O | |
| `.copy(text)`, `.copy(content)`, `.copy(title:content:)` | | closes with a HUD; the last loads content when it runs |
| `.copyPath(url)` or `.copyPath(urls)` | Control-Command-C | |
| `.paste(text)`, `.paste(content)`, `.paste(title:content:)`, `.paste(title:expansion:)` | | requires Accessibility; the lazy forms load when they run, `expansion` places the cursor |
| `.quickLook(url)` or `.quickLook(urls)` | Command-Y | preview inside the panel |
| `.moveToTrash(urls)` | Control-X | confirms, reloads, shows a toast, forgets the row |
| `.share(items)` | | system share menu |
| `.push(title) { page }` | | |
| `.runCommand(id, title:)` | | hidden while the command is unavailable |

Two modifiers compose: `.then { context in ... }` runs a step after the handler succeeds, such as recording calculator history after `.copy`, and reaches a submenu's entries too. `.recordingUse()` records a use of the row in `UsageService` when the action runs from one of your pages; root records its own.

The usual shortcuts are constants on `KeyCombo`: `.open`, `.openWith`, `.reveal`, `.quickLook`, `.copy`, `.copyPath`, `.remove`, `.removeAll`, `.edit`, `.duplicate`, `.new`, `.pin`, `.refresh`, `.primaryAction` and `.secondaryAction`. Use them so one key means one thing everywhere. Command-Y goes to an action whose shortcut is Command-Y, then to the row's `quickLookURL`.

Destructive actions take `style: .destructive` and a `Confirmation`; the confirm button is red. A `suppressionKey` lets the host offer "Don't ask again"; the host stores it as `<feature id>.<key>`.

## Commands

A `Command` has an ID unique in the feature, a title, keywords, up to three `CommandArgument`s (text, password or dropdown, each optional or required with a default), required permissions, a `Confirmation`, a suggested hotkey (almost always nil), a `Fallback`, `takesRootQueryOnTab`, a `LiveSubtitle`, `showsInRoot`, a `RunPolicy`, and row actions from `.withRowActions { ... }`.

Commands are read at registration and again each time `declarationChanges` fires, never per keystroke. To add or remove commands at runtime, as script commands and quicklinks do, keep the current list and send the signal after it changes. When a command disappears, the host keeps its alias and hotkey for 30 days. `Command.stableID(_:name:uniqueKey:)` makes a valid, stable ID from free text such as a file name.

`ActionContext.launch` says how a command started: `.root`, `.page`, `.hotkey`, `.fallback`, `.tabFromRoot`, `.deeplink`, `.suggestion`, `.command`, `.selection`, `.textExpansion` or `.settings`. For a fallback or a Tab handoff, `context.query` is the typed text, which also fills the first argument when the command declares one.

Declare an argument only for a value the user types. To hand data to a command from code, pass it in `.run(id, arguments:)`: undeclared values reach `context.arguments` too. When the target command is unavailable, the host shows a failure toast, and a `.runCommand` action pointing at it is hidden.

`LiveSubtitle(every:changes:fetch:)` refreshes a subtitle while the row is visible, at once when `changes` fires; `fetch` returns a `LiveSubtitle.Value` with an optional color.

A `HotkeyPreset` is a named set of hotkeys for the feature's commands, such as a layout scheme that matches another window manager. Declare presets in `hotkeyPresets`; settings applies one after showing conflicts.

## Pages

`Page` is one of four:

- `.list(ListPage)`: rows in sections from a `ListSource`, with an optional filter dropdown, detail pane, empty state and initial query.
- `.grid(GridPage)`: the same source drawn as cells; each row's icon fills its cell.
- `.detail(DetailPage)`: one `Detail` from a `DetailSource`, possibly streamed, possibly with a follow-up field.
- `.form(FormPage)`: fields, permissions, validation and a submit closure.

### List sources

`ListSource` has `filtering`, `load(_:)`, `actions(for:)`, `detail(for:)`, `changes` and `reloadsOnSettings`. The last two come from `RowSource`, which list, catalog and suggestion sources share, so one object can be several of them.

With `.host` filtering, `load` runs once per filter value and again when `changes` fires or a setting in `reloadsOnSettings` changes. The host matches titles and keywords, keeps sections in order, hides empty ones and those whose `visibility` says so (`.whenQueryEmpty` for "Pinned" or "Recently Used"), and orders rows inside a section by tier, then `rankHint`. One row may appear in more than one section; the selection is keyed by section and ID. `showsCount` draws the visible count after a heading.

With `.custom(debounce:)`, `load` runs for each query after the debounce, in a task the host cancels when the query changes. Call `try Task.checkCancellation()` between steps, set `titleHighlights`, and return a `nextPage` token for long results: the host loads the next page when the user scrolls near the end and appends it. `ListRequest.reason` says why a load happens (`.open`, `.query`, `.filter`, `.nextPage`, `.refresh`, `.reload`).

A `ListResult` can also return a `filter` that replaces the page's dropdown, such as when a tag was added while the page is open (the host falls back to the default option when the selected one is gone), a `notice` banner that stays above the rows, and `refreshAfter`, which loads again while the page is visible, as a Script Filter's `rerun` does.

`detail(for:)` runs after the selection settles, about 50 ms, and is cancelled if the selection moves. Return `nil` for no detail.

### Details

`Detail` is a body and metadata. Bodies are Markdown, text (optionally monospaced, with ANSI colors), rich text, an image from a file or bytes, a Quick Look preview of a file, a color, or a link. Metadata items are labels, links, tags, colors, dates and separators.

A `DetailSource` returns a stream of `DetailUpdate`s from `start()`: `.replace(detail)`, `.append(text)` and `.metadata(items)`. The host and the harness apply them with `Detail.apply(_:)`; the host draws at most one update per frame. `actions(for:)` receives the detail as shown, so a source keeps no copy of its output; the host asks for actions when the page opens, when a stream ends and when `actionsChanged` fires. Set `followUp` to turn the search field into a follow-up field: on Return the host cancels a stream still running, calls `followUp(_:)` and applies that stream on top. For a fixed detail, use `DetailPage(title:detail:actions:)`.

### Forms

Fields: `.text` and `.multiline` (either can color `{placeholders}`), `.password`, `.checkbox`, `.dropdown`, `.date`, `.files` (an open dialog), `.tags`, `.application`, `.description` and `.separator`. Read values with `values.text(_:)`, `bool(_:)`, `date(_:)`, `files(_:)` and `strings(_:)`. `requires` lists permissions submitting needs. `validate` may await and returns `FieldError`s by field ID; a string literal is enough, and a `range` points at the part at fault.

## Root search inputs

| Input | Use it for | How root uses it |
|---|---|---|
| `CatalogSource` | items people find by name, such as bookmarks | matched synchronously with apps and commands, ranked with learning; read again on `changes` or `reloadsOnSettings` |
| `InstantProvider` | answers computed from the query, such as a calculation | called on every keystroke on the main thread, **100 µs budget**; may claim the top slot |
| `AsyncProvider` | results that need work, such as files | called after `debounce(for:)` in a cancellable task; fills its own section, titled by `sectionTitle(for:)`, at most `maximumRows`; `takesOver(_:)` claims a query outright, such as a path |
| `SuggestionTrigger` | situational suggestions, such as a meeting about to start | asked when the context changes; Thompson sampling decides what shows |
| `UniversalActionProvider` | actions on text, URLs or files | asked for a selection in another app and for any row that `represents` one |

Each catalog source, live provider and suggestion trigger names its `namespace`. Root uses it to find who owns a remembered row. Namespaces are unique across sources, except that one object may be a catalog source, an instant provider and a trigger under one namespace, so an item keeps one ID wherever it shows. Root shows an item once per list.

A suggestion has a stable `id` for one situation, a `Row` (give one-off rows `memory: .never`), an `Urgency` (constant, a linear ramp, or exponential decay), an expiry, and `imminentFrom`, after which it may take a second slot. A trigger declares an `AcceptancePrior`, a refresh interval, `changes`, `reloadsOnSettings` and required permissions. Root skips a trigger whose permission is missing and never asks for it. `suggestions(at:)` throws when its work fails or is cancelled, so Root keeps what it had.

A source whose items can vanish behind its back, such as files deleted in Finder, adopts `RememberedRowValidator`: Root asks it in batches which remembered rows still exist and forgets the rest. An action can forget an item at once with `context.usage.forget(id)`.

Make universal action providers with `.text { text in ... }`, `.url { url in ... }` or `.files { urls in ... }`. The host prefixes each action's ID with the feature's, so IDs need only be unique within the feature.

## Settings

Declare typed keys in a `nonisolated enum`, so code off the main actor can read them, and read them through `context.settings`:

```swift
nonisolated enum EmojiSettings {
    static let skinTone = SettingKey("skinTone", default: SkinTone.none)
}

let tone = context.settings[EmojiSettings.skinTone]
context.settings[EmojiSettings.skinTone] = .medium
for await tone in context.settings.changes(of: EmojiSettings.skinTone) { ... }
for await name in context.settings.changes(ofAny: [EmojiSettings.skinTone.erased]) { ... }
```

Values can be `Bool`, `Int`, `Double`, `String`, `[String]`, `KeyCombo`, optionals of these, string enums that declare `SettingValue`, and `Codable` types that declare `CodableSettingValue`. They are stored as `<feature id>.<key name>`. An optional set to `nil` stays `nil`; `reset(_:)` returns to the default. A page whose rows depend on a setting lists the key in `reloadsOnSettings` instead of watching it.

`SettingsPane` lists sections of items: `.toggle`, `.picker`, `.textField`, `.secret`, `.stepper`, `.hotkey`, `.button`, `.list` (text, applications or folders), `.multiSelect` (options the feature supplies when the pane opens), `.application`, `.permission` (live status and a Grant button) and `.note`. A button runs like an action with `launch == .settings`: it can show toasts, ask questions and throw. Per-command aliases, hotkeys, on/off switches, the feature's `status` and its `hotkeyPresets` are added by the settings window for every feature.

`Feature.status` is what a background part of the feature wants the user to know, such as "Snippet expansion needs Input Monitoring" with the permission to grant. Settings shows it at the top of the pane; send `declarationChanges` when it changes.

API keys and tokens are secrets, never settings: `.secret("API key", name: "apiKey")` in the pane, `try await context.secrets.value(for: "apiKey")` in code. The live service keeps them in the Keychain.

## Services

Every service is a `Sendable` protocol reached through `FeatureContext`. Copy one into a background task freely.

| On the context | Does | Fake in KitTesting |
|---|---|---|
| `pasteboard` | copy, paste with a cursor position, read, recent text, watch other apps' copies | `FakePasteboard` with `simulateCopy` |
| `workspace` | open, open with, reveal, trash, apps for a URL, an app's name, frontmost app, launch | `FakeWorkspace` |
| `hotkeys` | hotkeys that are not commands | `FakeHotkeys` with `press` |
| `permissions` | read status and its changes; asking happens from actions | `FakePermissions` with `set` |
| `processes` | run subprocesses, streamed as bytes or as text | `FakeProcesses` with `stub` |
| `http` | requests and streamed responses, as lines or server-sent events | `FakeHTTP` with `stub` |
| `storage` | the feature's data and cache folders and the home folder, as paths | `FakeStorage`, a temporary folder |
| `settings` | typed settings | `FakeSettings` |
| `secrets` | secrets in the Keychain | `FakeSecrets` |
| `clock` | now, time zone, locale, calendar, sleep | `FakeClock` with `advance` |
| `usage` | record uses with snapshots, recents, counts, frecency, forget | `FakeUsage` |
| `fuzzyIndex` | the engine's matcher over your own strings | `FakeFuzzyIndexService` |
| `selection` | what is selected in the frontmost app | `FakeSelection` |
| `fileWatcher` | changes under folders | `FakeFileWatcher` with `simulateChange` |
| `fileDialogs` | open and save dialogs | `FakeFileDialogs` |
| `textExpansion` | keyword expansion in any app, and its status | `FakeTextExpansion` with `type` and `simulateStatus` |
| `log` | an `os.Logger` with your feature ID as category | |

Async service methods that do work are `@concurrent`, so they run off the main thread whoever calls them. `ProcessService.run` and the `HTTPStream` helpers throw `CancellationError` when the calling task is cancelled, so cut-off output is never taken for a result. Streamed bytes follow no character or line boundary: use `processes.textStream(_:)`, `stream.lines`, `stream.serverSentEvents` or `UTF8StreamDecoder` rather than decoding chunks yourself. `ProcessRequest.environment` entries replace the clean environment's, so a script can get a `PATH` with Homebrew.

A service only your feature needs, such as moving windows or reading calendar events, belongs in your package: a `nonisolated protocol`, a live implementation, an isolated one for scenarios, and a `FeatureServiceKey` that names both. Get it once in `init` with `context.service(MyServiceKey.self)`; tests pass a double with `fakes.override(MyServiceKey.self, with:)`. The feature never branches on the run environment. `WindowSketch.swift` shows the pattern. Propose a service for Kit when a second feature needs it.

A feature can offer a service to the rest of Slick through `provides`. Today that is `.clipboardHistory(reader)`, which answers `{clipboard offset=N}` from the whole history.

## Permissions

Slick never prompts by surprise.

1. List every permission the feature may need in the manifest, each with a one-sentence reason that starts with a verb.
2. Declare `requires` on the commands, actions and forms that need one. The host checks before running; when one is missing it shows the reason and a Grant button, and only that button asks the system.
3. When a handler finds a permission missing while it runs, such as Automation for whichever app is frontmost, return `.needsPermission(permission)`. The host shows the same card and runs again after a grant.
4. Read status with `context.permissions.isGranted(_:)` where behavior depends on it, and listen to `context.permissions.changes(of:)` to start work once the user grants it in System Settings. The context has no way to ask.
5. Services that would need a permission never prompt: `textExpansion.start` returns `.needsPermission`, `selection` returns `nil`, a paste throws `PasteError.permissionMissing`.

`.protectedFolder(.desktop)` and its siblings name folders macOS guards with its own prompt on the first read.

## Templates

`KitTemplates` renders one placeholder grammar for snippets, quicklinks and AI prompts, compatible with Raycast's dynamic placeholders.

| Placeholder | Attributes | Gives |
|---|---|---|
| `{clipboard}` | `offset=N` | the text copied N entries ago |
| `{selection}` | | the frontmost app's selected text |
| `{date}`, `{time}`, `{datetime}`, `{day}` | `offset`, `format`, `locale` | the date, moved and formatted |
| `{uuid}` | | a new UUID |
| `{cursor}` | | where the insertion point goes in a snippet |
| `{argument}` | `name`, `default`, `options` | a value the user types, up to three per template |
| `{snippet}` | `name` | another snippet's text, one level deep |

Modifiers follow a pipe and apply left to right: `{clipboard | trim | uppercase}`. They are `uppercase`, `lowercase`, `trim`, `percent-encode`, `json-stringify` and `raw`.

Offsets are signed steps with units `s`, `m` (minutes), `h`, `d`, `w`, `M` (months) and `y`: `{date offset="+2y -3d" format="yyyy-MM-dd"}`. `format` takes a Unicode date pattern; `locale` takes a BCP 47 identifier for the default format. Using both is a mistake.

The style decides default formatting. `.plain` inserts values as they are and honors `{cursor}`. `.url` percent-encodes every value. `.prompt` wraps clipboard, selection, argument and snippet values in triple quotes. `raw` turns the default off for one placeholder.

Braces that are not a known placeholder stay as typed, so code and JSON pass through. A known placeholder with a mistake also stays as typed and shows up in `template.issues` with its range, for an editor to point at. `template.arguments` lists what to ask the user for, and `template.commandArguments` turns them into search bar fields; `template.placeholderRanges` gives the UTF-16 ranges to color.

```swift
let environment = TemplateEnvironment(context: context.feature, arguments: context.arguments.values)
let rendered = await Template(snippet.text).render(in: environment)
try await context.pasteboard.paste(rendered.expansion)  // text plus where the cursor goes
```

`TemplateEnvironment(context:)` reads the clipboard and selection only when the template asks for them. `Expansion.charactersAfterCursor` counts characters as Swift does, one Left-arrow press each.

A typed keyword whose snippet has arguments returns `.runCommand(id, arguments:)` from the expansion handler: the host deletes the keyword and opens the panel on that command, which can push a form; the paste goes back to the same app.

## Storage

`context.storage.dataFile(_:)`, `dataDirectory`, `cacheFile(_:)` and `cacheDirectory` are paths and touch nothing, so they are safe in `init`. Whatever writes first creates the folder: `JSONFileStore.save` and `SQLiteDatabase(url:)` do. `homeDirectory` is the user's home in the app and a synthetic one elsewhere, so a scenario never shows the real home. The live service uses the data folder under Application Support; tests and scenarios use a temporary folder.

`JSONFileStore` keeps one Codable value in a file and writes it atomically, with dates to the millisecond. It suits small collections a person may read or edit.

`SQLiteDatabase` is a thin wrapper over the system SQLite: `execute` for schema, `run` and `query` with `?` parameters, `transaction`, and `migrate` with numbered steps kept in `PRAGMA user_version`. Files use write-ahead logging. `run` and `query` stop mid-scan and throw `CancellationError` when the calling task is cancelled. `SQLiteValue(optional)` binds nil as NULL. It is not `Sendable`; give it one owner, usually an actor:

```swift
actor HistoryStore {
    private let db: SQLiteDatabase

    init(url: URL) throws {
        db = try SQLiteDatabase(url: url)
        try db.migrate(["CREATE TABLE entry (id INTEGER PRIMARY KEY, text TEXT NOT NULL, date REAL NOT NULL)"])
    }

    func add(_ text: String, at date: Date) throws {
        try db.run("INSERT INTO entry (text, date) VALUES (?, ?)", [.text(text), .date(date)])
    }
}
```

## Threading

Feature packages compile with `@MainActor` as the default. That is right for the feature class, sources and closures. These need care.

Data types you encode, store or build in the background must be `nonisolated`: `nonisolated struct Bookmark: Codable, Sendable`. Without it, the type's `Codable` conformance is tied to the main actor and `JSONFileStore` or a `@concurrent` function cannot use it. The same goes for a string enum used as a setting, for constants a background function reads (`nonisolated static let namespace = "emoji"`), and for setting keys, which belong in a `nonisolated enum`.

Heavy work goes in a `@concurrent nonisolated` function: building more than a few hundred rows, counting words in a large text, parsing JSON. `ListSource.load` and `detail(for:)` start on the main actor, so await such a function from them. `ScriptSketch.ScriptFilter.parse(_:)` decodes and builds rows this way.

A protocol for your own service is `nonisolated protocol MyService: Sendable`, with `@concurrent` on the async requirements that do work, so even a plain implementation runs off the main thread. Implementations are `nonisolated final class` or actors.

A `DetailSource` streams from a task that is not on the main actor, such as `Task.detached` or a `@concurrent` function, and only yields to the continuation.

Subscribe to a stream before starting the task that reads it, as in `let entries = context.pasteboard.entries(); Task { for await entry in entries { ... } }`, so nothing sent in between is lost.

Read time only from `context.clock`. `Date()`, `Calendar.isDateInToday` and friends read the system clock, so a test cannot control them. `DaySections(clock:direction:)` titles dated sections (Today, Yesterday or Tomorrow, a weekday, then a date) from the injected clock.

To log, `import os` (`MemberImportVisibility` needs it in the file that interpolates) and use `context.log`. Anything from the user's data takes `privacy: .private`.

## Speed rules

- An instant provider has 100 µs per keystroke on the main thread. Reject queries that are not yours on the first character before parsing. No I/O, no locks that may wait.
- `actions(for:)`, `takesOver(_:)`, `sectionTitle(for:)`, `debounce(for:)` and every computed property the host reads run inside an interaction. Return what you have; do no I/O.
- Keep sources, providers and triggers in stored properties. The host reads declarations at registration and after `declarationChanges`; `harness.issues` reports one made anew on each read.
- Prefer host filtering. Hand over every row once; use `rankHint` and section visibility rather than custom filtering to order and hide.
- Custom filtering and async providers must stop when cancelled.
- `init(context:)` does no I/O. Features activate concurrently; `activate()` returns quickly and starts slow work in a task.
- No timers you do not need. The host refreshes `LiveSubtitle`s and `refreshAfter` only while they are visible.

## Testing

`FeatureHarness` builds a feature over `FakeServices` and drives it the way the host does, without a window.

```swift
let harness = FeatureHarness(EmojiFeature.self)
await harness.activate()
try await harness.run("search")
try await harness.setQuery("thumbs")
try await harness.performPrimary()
#expect(harness.fakes.pasteboard.pastedTexts == ["👍"])
```

What it can do:

| Area | Calls |
|---|---|
| declarations | `issues`, `command(_:)`, `activate()`, `deactivate()` |
| commands | `run(_:arguments:query:launch:)`, `runFallback(_:text:)`, `pressTab(_:on:)`, `rowActions(ofCommand:)` |
| pages | `open(_:)`, `setQuery(_:)`, `setFilter(_:)`, `reloadPage()`, `refresh()`, `loadNextPage()`, `pop()`, `pages`, `page`, `sections`, `rows`, `selectedRow`, `detail` |
| background work | `settle()`, `waitForChange()` |
| selection | `select(_:)`, `select(title:)`, `select(at:)`, `loadDetail()` |
| actions | `actions()`, `perform(_:)`, `performPrimary()`, `performSecondary()`, `submenu(_:)`, `submenu(_:in:row:query:launch:)`, `perform(_:row:query:launch:)`, `performToastAction()` |
| forms | `fill(_:_:)`, `fill(_:text:)`, `submit()` |
| detail pages | `followUp(_:)` |
| root search | `catalogRows()`, `instantAnswers(for:)`, `asyncSections(for:)`, `suggestions(at:)`, `rootActions(for:)`, `performRoot(_:on:query:)` |
| universal actions | `universalActions(for:)` with a selection or a row, `performUniversal(_:on:)` |
| settings | `pressSettingsButton(_:)` |
| what happened | `toasts`, `visibleToast`, `huds`, `isClosed`, `queryChanges`, `quickLooks`, `shares`, `confirmations`, `commandRuns`, `rootQueries`, `actionErrors`, `droppedRuns`, and every fake under `fakes` |

It follows the host's rules: host filtering through the fuzzy index with section visibility and rank hints, the first row selected after a load, permissions checked before anything runs and after `.needsPermission`, confirmations asked (`confirmationAnswer`), required form fields before `validate`, runs ordered by `RunPolicy`, toasts drawn as HUDs while the panel is closed, actions hidden while their command is in `unavailableCommands`, and a page loaded again after an action when it called `reload()`, when its source's signal fired or when a setting in `reloadsOnSettings` changed. Missing permissions throw `HarnessError.permissionRequired` unless `grantsMissingPermissions` is set, in which case the harness asks the fake permission center as if the user pressed Grant. Thrown errors reach the test unless `throwsActionErrors` is false, in which case the harness shows them as the host does. Debounces are skipped. Compare outcomes with `outcome.kind == .keepOpen`.

Background work is never awaited by itself. After a fake plays something, such as `simulateCopy`, `permissions.set`, a settings write or `simulateChange`, call `try await harness.settle()`: it returns once every consumer of the fakes' streams has handled what it received, and reloads the open page if its source changed. `waitForChange()` waits for the page's source to signal and reloads. A stream a feature makes and never reads holds `settle()` until the test's time limit, so give suites `.timeLimit(.minutes(1))`.

Move time with `harness.fakes.clock.advance(by:)`. The fake clock starts on Saturday 14 November 2026 at 09:30 UTC in the `en_US_POSIX` locale, which does not group digits; pass `FakeClock(locale:)` to test formatting.

To pass a fake of your own service, override its key before making the feature:

```swift
let fakes = FakeServices()
fakes.override(WindowMoverKey.self, with: RecordingMover())
let harness = FeatureHarness(WindowFeature.self, fakes: fakes)
```

Test data is synthetic: no real file names, paths under the home folder, clipboard contents or contacts. `FakeStorage` uses a fresh temporary folder and deletes it afterwards. Constants used inside a fake's `@Sendable` handler must be `nonisolated`.

## Recipes

Each built-in feature maps onto Kit as below. The sketch files run each recipe through the harness.

| Feature | How | Sketch |
|---|---|---|
| Clipboard history | `activate()` subscribes to `pasteboard.entries()` and records in a task; a `.custom` list over SQLite with paging, highlights and a type `FilterDropdown`; rows carry their summary as payload and `represent` their text; lazy `.paste`/`.copy` with `.then`; `provides: [.clipboardHistory]`; `isEnabledByDefault: false` | `ClipboardSketch.swift` |
| Window management | a table of no-view commands with `requires: [.accessibility]`, serial by default so cycling works; the mover through a `FeatureServiceKey`; `.needsPermission` when access goes away; `hotkeyPresets` | `WindowSketch.swift` |
| File search | an `AsyncProvider` with `takesOver` for "/" and "~" and a per-query title; a `.custom` list with a `.preview` detail and a `notice` while access is limited; rows `represent` their files; recents from usage snapshots | `FileSearchSketch.swift` |
| Calculator | an `InstantProvider` with `claimsTop`, `completion` and `memory: .never`; copy with `.then` to record history; a history page with `DaySections` and `.showRoot(query:)` | `CalculatorAndEmojiSketch.swift` |
| Quicklinks | a `JSONFileStore`; a command per quicklink with `template.commandArguments` and `.withRowActions`; `.openWith(resolving:)`; a form; `Fallback` | `Examples/BookmarksFeature.swift` |
| Emoji | a `GridPage` with host filtering: Recent and Pinned sections `.whenQueryEmpty`, recency and pins as `rankHint`; the skin tone in `reloadsOnSettings`; `.paste(...).recordingUse()` | `CalculatorAndEmojiSketch.swift` |
| Script commands and filters | scan a folder with a `@concurrent` function; `fileWatcher` and `declarationChanges`; `Command.stableID`; silent mode `dismiss()`es then reports; `textStream` into a streamed `DetailPage`; a colored `LiveSubtitle`; a Script Filter list with `.custom` filtering, `alternates` and `refreshAfter` | `ScriptSketch.swift` |
| AI | a command with `takesRootQueryOnTab`; a `DetailSource` reading `serverSentEvents` off the main thread; `actions(for:)` from the shown detail; `followUp`; the key in `secrets`; `.replace` after setup | `AICalendarSnippetsSketch.swift` |
| Calendar | a `SuggestionTrigger` with its own namespace, an urgency ramp, `imminentFrom` and `memory: .never`; `DaySections(direction: .future)`; `permissions.changes(of: .calendars)`; `.multiSelect` of calendars | `AICalendarSnippetsSketch.swift` |
| Snippets | `textExpansion.start` with `ExpansionResult`; `.runCommand` for snippets with arguments; `statusChanges()` and permission changes into `Feature.status`; one object as catalog source and instant provider | `AICalendarSnippetsSketch.swift` |
| Universal actions | `.text`, `.url` and `.files` providers, for selections and for rows that `represent` them | `Examples/BookmarksFeature.swift` |
| Settings | `SettingKey`s in a `nonisolated enum` and a `SettingsPane` | `Examples/BookmarksFeature.swift`, `Kit/SettingsTests.swift` |

## Before review

- `harness.issues` is empty in a test that has opened the feature's pages and actions.
- Every command, action and form that needs a permission declares it, and the manifest gives the reason.
- Stored and background data types, and setting keys, are `nonisolated`.
- Nothing reads `Date()` or the system calendar's notion of today.
- Row IDs are stable across launches, and `actions(for:)` works from a row rebuilt from a snapshot.
- Instant providers reject foreign queries on the first character.
- Sources, providers and triggers live in stored properties.
- Tests use the fakes and synthetic data only, and `settle()` instead of yields or sleeps.
- `make lint` passes and the package builds with no warnings.
