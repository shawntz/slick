<div align="center">

<img src="site/assets/icon/icon-256.png" width="128" height="128" alt="Slick's icon: a purple glass rounded square with a lightning bolt made of two translucent blades.">

<h1>Slick</h1>

<p><strong>An open-source macOS launcher in the class of Raycast and Alfred that draws in real Liquid Glass and learns which result you pick.</strong></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/media/hero-dark.gif">
  <source media="(prefers-color-scheme: light)" srcset="site/media/hero-light.gif">
  <img src="site/media/hero-light.gif" width="940" alt="A recording of Slick's search panel in the dark or light mode of your GitHub theme, over a matching gradient wallpaper. The panel opens and suggests Mail, Calendar and Music. Typing “n” lists News, Notes, a window command, two web searches, TextEdit and Sleep. Typing “o” selects Notes and completes the field to “notes”, with the rest of the name in grey, above TextEdit, Console, Font Book, Screenshot, Mission Control and System Information. Return picks Notes and the panel closes. The scenario notes the launch instead of opening the app. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
</picture>

<sub>Two typed letters find Notes, and the field completes its name. Recorded from the assembled app with Apple's own apps.</sub>

<p><strong>Pre-release, with no download yet.</strong> The assembled app passes all 44 of its end-to-end scenarios against made-up data, and nobody has run the live launcher on a real Mac yet.</p>

<p>
  <a href="#speed-measured-inside-the-app">Speed</a> ·
  <a href="#real-liquid-glass">Glass</a> ·
  <a href="#it-learns-what-you-pick">Learning</a> ·
  <a href="#every-feature-and-its-status">Features</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#privacy">Privacy</a>
</p>

</div>

## What it does

### Speed, measured inside the app

Every path that runs while you type has a budget for main-thread time. `make bench` measures each one inside the release app, and in the latest run, with sixteen features registered, every budget passed.

<div align="center">

<img src="site/media/clip-narrow-dark.gif" width="720" alt="A recording of Slick's search panel in dark mode over a purple gradient wallpaper. Typing “c” lists seven apps, from Calendar to ColorSync Utility, and completes the field to “calendar”. Typing “a” narrows the list to Calendar, Calculator, Calculator History, Image Capture, Photo Booth, a crates.io search and Quit All Applications. The selection glides down three rows to Image Capture and back up one. Typing “lc” leaves Calculator at the top, above Calculator History and three web searches for “calc”. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">

<sub>The list narrows with each letter, and the selection glides between rows.</sub>

</div>

| What was measured | Median | p99 | Budget |
|---|---|---|---|
| Root search over 3,146 items, with the engine's ranking | 0.026 ms | 0.070 ms | 0.5 ms at p99 |
| Root search over 10,146 items, with the engine's ranking | 0.041 ms | 0.134 ms | 1.5 ms at p99 |
| A keystroke over 3,146 items, from the field editor to the screen commit | 1.34 ms | 4.60 ms | 3 ms median, 5 ms p99 |
| A keystroke over 10,146 items, from the field editor to the screen commit | 1.42 ms | 4.73 ms | 3 ms median, 5 ms p99 |
| The launcher's own summon path, not counting the system making the panel key and drawing the glass's key look | 0.024 ms | 0.095 ms | 1 ms |
| Opening the action panel over 10,146 items | 1.77 ms | 3.44 ms | 8 ms at p99 |
| First pixels on screen after the summon call | 26.5 ms | 46.8 ms | none |

These numbers come from an Apple M5 with macOS 27.2 in November 2026. The release app ran through LaunchServices while other builds kept the load average between 3 and 8. Budgets count main-thread CPU time. First pixels count wall time to the first frame, measured in the app's recording build. In all 30 summons that first frame already showed the finished glass.

The keystroke margin is thin. Earlier the same day the same bench missed the 5 ms budget at 10,146 items, with a p99 of 5.58 ms. Nobody has measured other launchers on this Mac, so these numbers compare Slick only with its own budgets.

The [latency rules](docs/ARCHITECTURE.md#latency-rules) say how. No file, network or cross-process call may run on the main thread inside a keystroke. The Rust matcher checks bit masks before it scores a title, and it allocates no memory during a query.

### Real Liquid Glass

The panel is one `NSGlassEffectView`, the system's own Liquid Glass, not a blur imitation. Glass shows its full look only while its window is key. So Slick keeps a single key panel and draws the action panel, previews, confirmations and forms inside it. It makes the panel key before it shows it, so the first frame of a summon already has the finished look.

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="site/media/actions-dark.gif">
        <source media="(prefers-color-scheme: light)" srcset="site/media/actions-light.gif">
        <img src="site/media/actions-light.gif" width="380" alt="A recording of Slick's search panel in the dark or light mode of your GitHub theme, over a matching gradient wallpaper. The panel suggests Calendar, Music and Mail. Typing “cal” selects Calendar and completes the field to “calendar”. Command-K opens the action panel beside the results. It lists Open, Show in Finder, Show Package Contents, Copy Name, Copy Bundle Identifier and Copy Path, each with a keyboard shortcut, then Add to Favorites and Set Alias. The selection moves down two entries. Typing “f” narrows the list to three entries and “fav” to Add to Favorites. Return runs it, the action panel closes and the bar at the bottom shows “Added to Favorites”. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
      </picture>
      <br><sub>Command-K opens the actions of the selected result inside the same glass, and typing filters them.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="site/media/clip-themes-dark.gif" width="380" alt="A recording of Slick's search panel in dark mode over a purple gradient wallpaper, with “ca” typed. The theme changes from Standard to Graphite, Ocean, Ember, Violet and back to Standard while the panel stays open, and the selection moves down a row after each change. Graphite marks the row with a flat grey fill, Ocean tints the glass blue, Ember tints it warm red and Violet uses a purple lens. The themes were switched through the theme setting, not the settings window. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
      <br><sub>Switching themes restyles the open panel at once. The theme editor and sharing are still in progress.</sub>
    </td>
  </tr>
</table>

### It learns what you pick

Pick a lower result twice for the same query, and it becomes the first. One stray pick does not change it. A learned pick even outranks an exact title match, on purpose. Before you type, the same engine suggests what you are likely to open next from the time of day, the app in front and what you just used.

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/media/clip-learn-dark.gif">
  <source media="(prefers-color-scheme: light)" srcset="site/media/clip-learn-light.gif">
  <img src="site/media/clip-learn-light.gif" width="720" alt="A recording of Slick's search panel in the dark or light mode of your GitHub theme, over a matching gradient wallpaper. The panel opens, and typing “bo” lists Books first, then three window commands, Font Book and Photo Booth. The selection moves down to Font Book, Return picks it and the panel closes. The panel opens again and suggests Font Book, but “bo” still lists Books first, so Font Book is picked a second time. On the third search for “bo”, Font Book is first and Books second. Each time the panel opens, its first frame already shows the finished glass. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
</picture>

<sub>Font Book is picked twice for "bo", and on the third search it is first, above Books.</sub>

</div>

### Calculator, clipboard, emoji and files

The app registers sixteen feature packages. These clips show four of them in the assembled app. File search is still in progress, and the other three are available.

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="site/media/clip-calc-dark.gif" width="380" alt="A recording of Slick's search panel in dark mode over a purple gradient wallpaper. Typing “1250 * 1.08” shows only web searches until the expression is complete, then the answer 1,350 at the top. Escape clears the field. Typing “5 km in mi” shows “5 km” on the way, then the answer 3.10686 mi. Return copies the answer and the panel closes. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
      <br><sub>The calculator answers as you type, and Return copies the answer.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="site/media/clip-clipboard-light.gif" width="380" alt="A recording of Slick's search panel in light mode over a pale lilac gradient wallpaper. Typing “clip” completes to Clipboard History, and Return opens it as a list of four copied items with a detail pane: a note with its character and word count, a link, a color and a line of code. Moving down shows the link, then the color as a purple swatch with its hex value. Command-K opens the item's actions: Paste, Copy to Clipboard, Pin, Delete, Delete All, Search the Web, Search With and Define Word. Escape closes them, and Return pastes the color and the panel closes. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons. The copied items are made up for the clip.">
      <br><sub>Clipboard history shows what you copied and pastes it back. It stays off until you switch it on.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="site/media/clip-emoji-light.gif" width="380" alt="A recording of Slick's search panel in light mode over a pale lilac gradient wallpaper. Typing “emoji” selects Search Emoji and Symbols, and Return opens a grid of smileys. Typing “heart” fills the grid with hearts and heart-themed emoji, four rows of eight. The selection moves right two cells and down one, and the bar at the bottom names the selected emoji, Two Hearts, with Paste on Return. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons.">
      <br><sub>Search Emoji and Symbols opens a grid that filters as you type.</sub>
    </td>
    <td width="50%" valign="top">
      <img src="site/media/clip-files-light.gif" width="380" alt="A recording of Slick's search panel in light mode over a pale lilac gradient wallpaper. Typing “files” selects Search Files, and Return opens it with a note that Desktop, Documents and Downloads are not searched until they are chosen. Typing “budget” lists seven matching files and folders from a made-up home folder. The detail pane beside the list shows a placeholder where a preview would be, because the sample files do not exist on disk, and below it the kind, size, modified date and folder of the selected file. Moving down the list shows the next two files. Recorded from the assembled app running a scripted scenario, with Apple's own apps and their real icons. File search is still in progress: it is proven over a sample index, and indexing real folders has not run on a Mac yet.">
      <br><sub>Search Files shows each match's kind, size, date and folder. It is proven over a sample index, and indexing real folders has not run on a Mac yet.</sub>
    </td>
  </tr>
</table>

### Every feature and its status

[support/features.json](support/features.json) is the one list of what Slick does and how far along each part is. `scripts/sync-features.py` writes the tables below from it, so they cannot claim more than the data does. Available means a scripted end-to-end scenario proves the feature in the assembled app, against made-up data. In progress means the code exists, and each line says what is proven and what has not run yet.

<!-- features:start -->
<!-- Generated by scripts/sync-features.py from support/features.json. Edit the JSON, then run the script. -->

As of 2026-11-15, 11 of 24 features are available and 13 are in progress.

#### Core

7 of these 8 are available and 1 is in progress.

| Available | What it does |
|---|---|
| Liquid Glass panel | A real system glass panel, not a blur imitation, with a selection lens that glides between rows. |
| Fuzzy search | An in-house matcher that understands prefixes, acronyms, camelCase, word order and typos. |
| Learns your habits | Pick a result twice for a query and it becomes the top hit. Everything it learns stays on your Mac. |
| Suggestions before you type | Ranks what you are likely to open next from the time of day, the app in front and what you just used. |
| Apps and System Settings | Open, quit, hide or reveal any app, and jump straight to a System Settings pane. |
| Hotkeys, aliases and favorites | Give any item a global hotkey or a short alias, and pin favorites to the top. |
| Action panel | Every result has more actions behind Command-K, with their own shortcuts. |

| In progress | What it does |
|---|---|
| Themes | Change tint, clarity, lens style, accent, text size and row height, then save and share the theme as a file. Switching themes works in the launcher; the editor and sharing are not tested in the app yet. |

#### Built-in tools

4 of these 16 are available and 12 are in progress.

| Available | What it does |
|---|---|
| Calculator | Math, percentages, units, dates and time zones, answered as you type and copied with Return. Currency conversions fetch rates the first time you ask for one. |
| Clipboard history | Search text, links, images and files you copied, and paste them back. |
| Quicklinks and web search | Open sites and searches with a keyword, and fall back to the web when nothing local matches. |
| Emoji picker | Search emoji and symbols by name and paste them. |

| In progress | What it does |
|---|---|
| File search | An own index of file names that answers in milliseconds, with folder browsing. Proven in the launcher over a sample index; indexing your real folders has not run on a Mac yet. |
| Snippets | Saved text with placeholders that you find and paste from the launcher. Expanding a keyword as you type in other apps has not run on a Mac yet. |
| Window management | Halves, thirds, quarters, centering and moving windows between displays. Proven against simulated windows; moving real windows has not run on a Mac yet. |
| System commands | Sleep, lock, empty the Trash, toggle dark mode, eject disks and more. Proven against simulated services; the real system calls have not run on a Mac yet. |
| Script commands | Run your own scripts from the launcher, with arguments and live output. The commands and their arguments are proven in the launcher; running a real script has not been tested in the app. |
| Universal actions | Act on the text or files selected in any app. The actions show for results in the launcher; reading the selection in another app has not run on a Mac yet. |
| Dictionary | Look up a word with define, check its spelling, and copy or paste the definition. Proven in the launcher with sample entries; the Mac's own dictionaries have not been read in the app yet. |
| Calendar and reminders | Your day's events, a meeting to join when it is about to start, and new events and reminders from the launcher. Proven with a sample day; reading your real calendars has not run on a Mac yet. |
| Contacts | Find a person and call, message, email or FaceTime them. Proven with sample contacts; reading your real contacts has not run on a Mac yet. |
| Browser bookmarks | Search the bookmarks of Safari, Chrome, Firefox and other browsers and open them. Proven with sample bookmarks; reading a real browser's files has not run on a Mac yet. |
| Menu items | Search and run any menu command of the app in front. Proven with a sample app's menus; reading a real app's menus has not run on a Mac yet. |
| AI, with your own key | Ask questions with Apple's on-device model or a provider you configure. Nothing is sent unless you ask. Proven in the launcher with a simulated model; a real model has not answered yet. |

<!-- features:end -->

## Build from source

You need macOS 27 with Xcode 27, and rustup, which `brew install rustup` installs. It fetches the Rust version pinned in [rust-toolchain.toml](rust-toolchain.toml) on first use.

```sh
git clone https://github.com/shawntz/slick.git
cd slick
make bootstrap   # check Xcode and the SDK, build the Rust core, resolve the Swift packages
make run         # build build/Slick.app and open it
```

The app runs on macOS 26 or later on Apple silicon. It is developed and tested on macOS 27, and macOS 26 is untested. `make test` runs every Rust and Swift test, `make selftest` checks the built app without showing a window, and `make help` lists every other target.

`make app` signs with your Apple Development identity when your keychain has one, and ad hoc otherwise. macOS drops permission grants such as Accessibility after each ad hoc rebuild, so a development certificate saves you from granting them again.

### Your first launch

Slick has no Dock icon. A bolt appears in the menu bar, and onboarding opens in six steps: Welcome, Hotkey, Optional Features, Permissions, Theme and Done.

- Command-Space is the default hotkey, and Spotlight holds it on a new Mac. Until you free it, the hotkey waits, and Open in the bolt menu opens the launcher instead. The Hotkey step shows how to turn off Spotlight's shortcut in the system's own words, with a button that opens Keyboard settings. A line turns green the moment ⌘Space is free, and a HUD says "⌘Space Now Opens Slick". You can also record another hotkey.
- Clipboard History and File Search start off. The Optional Features step lists both. Clipboard History's switch starts off there, and File Search's starts on because it is suggested. Neither switch takes effect until you press Continue.
- Slick asks macOS for no permission at launch. The Permissions step lists only what the features you kept on can need, and asks macOS only when you press Allow. You can skip every row. Each feature asks again through a card in the panel the first time you run something that needs it.

This is what the code does. Nobody has run it live on a Mac yet.

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/media/settings-general-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="site/media/settings-general-light.png">
  <img src="site/media/settings-general-light.png" width="720" alt="Slick's settings window in the dark or light mode of your GitHub theme, over a matching gradient wallpaper, on the General pane. The hotkey is ⌘Space. Under it a note reads “Spotlight holds ⌘Space, so it does not open Slick yet. Turn off Spotlight's shortcut in System Settings, and it will.” with an Open Keyboard Settings button. Below are Open at login, off, Show in the menu bar, on, and the Panel settings. The scenario played Spotlight holding the shortcut. The window is shown without focus, as the scenario opens it, so its selection and switches are grey. Captured from the assembled app running a scripted scenario.">
</picture>

<sub>While Spotlight holds ⌘Space, the General pane in settings says so and opens Keyboard settings. Captured from the assembled app in a scenario where Spotlight holds the shortcut.</sub>

</div>

Inside the panel, Command-K opens the actions of the selected result. The [keyboard table](docs/ARCHITECTURE.md#host) lists every other key.

## How it is built

Swift 6 and AppKit draw the panel and run the features. A Rust core does the matching, ranking, learning, math and file indexing. It links in as one static library behind a C ABI, and only the CoreBridge package sees its header.

| Part | Where | What it does |
|---|---|---|
| Rust core | [core/](core) | Matcher, learning model, ranking engine, calculator and file index |
| Kit | [Packages/Kit](Packages/Kit) | The contracts every feature is written against, with a fake for every service |
| LauncherUI | [Packages/LauncherUI](Packages/LauncherUI) | AppKit drawing: the glass panel, query field, Core Text list, grid, detail pane and forms |
| Host | [Packages/Host](Packages/Host) | The feature runtime, navigation, the action panel and the keyboard model |
| Root | [Packages/Root](Packages/Root) | Root search: engine queries, suggestions, favorites, aliases and learning |
| Platform | [Packages/Platform](Packages/Platform) | Live system services such as hotkeys, the pasteboard, icons and permissions |
| SettingsUI | [Packages/SettingsUI](Packages/SettingsUI) | The settings window and onboarding |
| Features | [Packages/Features](Packages/Features) | Sixteen packages, one per feature |
| App | [Packages/App](Packages/App) | The executable that joins the rest |

Each module is its own package, so a syntax error in one feature cannot stop another feature's tests. In the latest full run, 271 Rust tests and all 25 Swift packages passed with warnings as errors. All 44 scenarios passed headless and on screen, and the selftest passed 142 of 142 queries. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is the contract for the layout, the dependency rules, the ranking contract and the latency and glass rules.

### Write a feature

A feature is one Swift package under `Packages/Features` that depends on Kit. It describes its commands, rows, pages and settings as data, and the host draws them. Every side effect goes through a service on the feature's context, so the same code runs against the Mac in the app and against fakes in tests. This is the smallest one in the guide:

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

One line in [Features.swift](Packages/App/Sources/SlickApp/Features.swift) registers a feature with the app. [docs/FEATURES.md](docs/FEATURES.md) walks through this feature, a searchable list and a full bookmarks feature, which all compile and run as tests. Then it covers every part of Kit and the rules that keep a feature fast.

## Privacy

Slick has no account and no telemetry. What it learns stays on your Mac.

### What is stored, and where

Everything lives in `~/Library/Application Support/Slick`. Settings go to the app's own preferences.

- `app.root` holds what the launcher learns, as a snapshot and an append-only event log.
- `Features/<feature>` holds each feature's own files, such as snippets, quicklinks, your scripts and AI chats. The clipboard history database appears there only once you switch Clipboard History on.
- `Caches` holds the icon cache, and `Themes` holds your own themes.
- `launcher.lock` marks the one running copy.

Clipboard history never stores items an app marks as concealed, transient or auto-generated. File search, once you switch it on, indexes the names and dates of the files in your home folder and never reads their contents. It skips Library and packages such as apps, and it leaves out Desktop, Documents, Downloads and iCloud Drive until you include them.

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/media/settings-learning-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="site/media/settings-learning-light.png">
  <img src="site/media/settings-learning-light.png" width="720" alt="Slick's settings window in the dark or light mode of your GitHub theme, over a matching gradient wallpaper, on the Learning pane. A note says everything learned stays on this Mac. It reports 7 runs of 5 items and 11 queries, its size on disk in bytes and the day learning started, then a Pause learning switch. Most used lists Font Book and Calendar with 2 runs each and TextEdit, Maps and Notes with 1 run, each with its real icon and a delete button. The picks were made by the scenario. The window is shown without focus, as the scenario opens it, so its selection and switches are grey. Captured from the assembled app running a scripted scenario.">
</picture>

<sub>The Learning pane shows what was learned on this Mac. It can forget an item, pause learning or erase everything.</sub>

</div>

### What leaves the Mac, and when

Nothing leaves at launch. Slick makes a network request only when you ask for something that needs one:

- a web search
- a currency conversion, which downloads exchange rates
- a question to an AI provider you set up
- web icons for script commands, which start off

Slick asks for no permission at launch either. It asks for each one only after you press a button: Allow in onboarding, Grant in settings, or the button on the panel's permission card. The one exception is Local Network, which macOS asks for by itself the first time Slick connects to an AI model server on another machine. No feature uses Location, the camera, the microphone, Screen Recording or Focus.

The tests use made-up data. They never read your pasteboard, walk your home folder or make a network request.

To erase everything, quit Slick from the bolt menu, move `~/Library/Application Support/Slick` to the Trash and run `defaults delete com.shawnschwartz.slick`. Permissions you granted stay with the app until you remove them in System Settings.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), then [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). CI runs `make lint`, every test and the selftest on every push to main and every pull request. If you change [support/features.json](support/features.json), run `scripts/sync-features.py`. It rewrites the tables in this README and the feature list on the website, and `--check` fails when either is stale. Report a security problem privately, as [SECURITY.md](SECURITY.md) says.

## License

MIT. See [LICENSE](LICENSE).

---

The website will be at [slick.computer](https://slick.computer).

<sub>Slick follows Raycast and Alfred, and credits them for the ideas it builds on.</sub>
