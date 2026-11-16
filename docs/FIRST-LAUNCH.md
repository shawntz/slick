# Your first launch

This guide says what Slick does the first time you start it: what appears, what it asks for and when, what it reads and stores, and ten things to try.

When 0.1.0 was cut, nobody had started the live launcher. Every test, scenario, selftest and benchmark ran in its own temporary folder against made-up apps, files, contacts and calendars. So a first launch is where the code below meets a real Mac, and each of the ten things says what nobody had seen work yet.

## How to start it

From a release:

1. Install it with `brew install --cask shawntz/tap/slick`, or download the zip from the latest release on GitHub and move Slick to Applications.
2. Open Slick from Applications.

From a checkout:

1. Make sure no `make bench`, `make scenario` or `make selftest` run is going. If one runs, macOS may bring that copy forward instead of starting yours.
2. Run `make run`. It builds the release app into build/Slick.app and opens it through LaunchServices.

To quit, use Quit in the bolt menu in the menu bar. Quitting waits up to 5 seconds while the launcher writes what it learned.

Your data goes to `~/Library/Application Support/Slick`. Settings go to the app's own preferences file. Nothing leaves the Mac unless you ask for something that needs the network, such as a web search, a currency conversion or an AI provider you set up, or unless you agree to update checks.

## What appears, in order

1. No Dock icon. A bolt appears in the menu bar at once.
2. The onboarding window opens in front at the same moment.
3. Spotlight holds Command-Space on a new Mac, so the launcher hotkey waits. Nothing is bound and no error shows. The bolt menu starts with "Spotlight Holds ⌘Space" and an Open Keyboard Settings item, above Open, Settings and Quit. Until the hotkey is free, the menu's Open item opens the launcher.
4. In the background, with no prompt, the sixteen features register and fourteen of them turn on. Clipboard History and File Search start off.

Onboarding, step by step:

1. **Welcome.** What the launcher is, and that learning stays on the Mac. Button: Get Started.
2. **Hotkey.** The recorder shows ⌘Space. While Spotlight holds it, the step shows three steps in the system's own words to turn off Spotlight's shortcut, an Open Keyboard Settings button, and a waiting line that turns green the moment ⌘Space is free. You may record another hotkey instead.
3. **Optional Features.** Clipboard History, off, and File Search, whose switch starts on because it is suggested. The switches take effect when you press Continue.
4. **Permissions.** One row per permission that the features that are on can need, with each feature's reason, and Skip and Allow buttons. Nothing is asked of macOS until you press Allow. With File Search left on, this list is long: up to fifteen rows. You can skip every row. Each feature asks again, through a card in the panel, the first time you run something that needs it.
5. **Theme.** The seven built-in themes, among them Beam and Clear. Picking one applies it.
6. **Done.** How to open the launcher. In a release, this step also has a switch, Check for Updates Automatically, that starts on. Slick stores your choice when you press Start, and checks nothing before that.

Closing the onboarding window with its close button means onboarding opens again at the next launch, and switches you did not continue past are not applied.

When ⌘Space becomes free, a HUD says "⌘Space Now Opens Slick". The launcher checks every 2 seconds for 10 minutes, then every 30 seconds, and at once whenever the settings or onboarding window opens.

## Every permission, and when it is asked

No permission is asked at launch. Each one is asked only after you press a button: Allow in onboarding, Grant in settings, or the button on the panel's permission card, which shows the first time you run something that needs it. For permissions that only System Settings can grant, the panel closes, a HUD says what to allow, and Slick opens that pane unless macOS showed its own dialog. A grant made in System Settings does not run the waiting command. A toast such as "Accessibility Allowed, Run Paste Snippet Again" asks you to run it again.

| Feature | On at first launch | Permission | When it is asked |
|---|---|---|---|
| Apps | yes | none | |
| Clipboard History | no | Paste from Other Apps | when you turn the feature on and its history page shows Allow Access. macOS 27.2 has no request for it, so Slick opens System Settings |
| Clipboard History | no | Accessibility | when you paste an entry into another app |
| Snippets | yes | Accessibility | when you paste a snippet, or run Fill In Snippet |
| Snippets | yes | Input Monitoring and Accessibility | when you turn on keyword expansion |
| Quicklinks | yes | Accessibility | only for a quicklink that uses `{selection}` |
| Emoji | yes | Accessibility | when Return pastes an emoji into the app you were using |
| Window Management | yes | Accessibility | on the first window command or Switch Windows |
| System | yes | Automation of Finder | Empty Trash |
| System | yes | Automation of System Events | Toggle Dark Mode |
| System | yes | Automation of the login window | Log Out, Restart, Shut Down |
| Script Commands | yes | Accessibility | when a list script's result is pasted. Your scripts run as you and may raise their own prompts, which name Slick |
| Calculator | yes | Accessibility | only when you paste an answer. Return copies, which needs nothing |
| File Search | no | Desktop, Documents, Downloads, iCloud Drive, removable volumes, network volumes | when you include that place in Choose Folders to Search. Each one has its own prompt. Full Disk Access spares all but iCloud Drive |
| File Search | no | Full Disk Access | optional, from the same place. macOS has no request, so Slick opens System Settings |
| Dictionary | yes | Accessibility | only when you paste a definition or a word |
| Calendar and Reminders | yes | Calendars | My Schedule, Create Event, and the meeting suggestion before you type |
| Calendar and Reminders | yes | Reminders | My Reminders, Create Reminder |
| Contacts | yes | Contacts | Search Contacts, and before contacts can join root search |
| Browser Bookmarks | yes | Full Disk Access | only if you choose Safari. Other browsers need nothing, and no browser is read until you choose one |
| AI | yes | Accessibility | when it reads the text you selected in another app or pastes an answer |
| AI | yes | Local Network | macOS asks the first time Slick connects to a model server on another machine on your network |
| Menu Items | yes | Accessibility | Search Menu Items |

No feature uses Location, the camera, the microphone, Screen Recording or Focus. The app's property list has a plain sentence for every permission above, and the release entitlements grant Apple Events, Contacts and Calendars and nothing else.

macOS ties a grant to the app's signature. A release asks again for what a build from a checkout already had.

## What Slick reads and stores at first launch, with no action from you

Reads:

- The apps in /Applications, /System/Applications, /System/Library/CoreServices/Applications and ~/Applications: each app's Info.plist and localized name, and its icon for the icon cache. It watches those folders for changes.
- The System Settings panes and their search terms, from the system's own extensions.
- On the first launch only, for light learning priors: the apps in your Dock, the apps that run now, and Spotlight's use counts for apps in the system's app folders. No prompt.
- The status of each permission, through calls that never prompt.
- To find out whether Full Disk Access is on: the Time Machine settings file, then the Mail and Messages library folders. Without Full Disk Access macOS refuses these reads quietly. Slick reads nothing in them.
- The front app, power source, displays and audio output, for suggestions before you type. Focus is never read.
- The macOS shortcuts that hold key combinations, to know whether Spotlight holds ⌘Space.
- The system's time zone files, for the calculator.
- Nothing from your browsers, contacts, calendars, clipboard or documents.

If you leave File Search's switch on in onboarding and press Continue, it starts indexing the names of the files in your home folder in the background. It skips Library, every package such as an app or a photo library, and Desktop, Documents, Downloads and iCloud Drive until you include them. It reads names and dates, never contents.

Stores, all under `~/Library/Application Support/Slick`, a folder only your account can open:

- `launcher.lock`, which marks the one running copy.
- `app.root`: what the launcher learns, as a snapshot and an event log.
- `Features/<feature>`: each feature's own files, such as `snippets.json`, `quicklinks.json`, the script folder and AI chats. The clipboard history database appears only once Clipboard History is on.
- `Caches`: the icon atlas.
- `Themes`: your own theme files.

Network: none at launch. The first request happens when you search the web, convert a currency, ask an AI provider you set up, or turn on web icons for scripts. In a release, once Check for Updates Automatically is on, Slick also asks GitHub once a day whether a newer version exists. That request carries the version numbers of Slick and its updater and, like any web request, your IP address. A build from a checkout has no updater.

## Ten things to try

Together these touch every live path that had never run when 0.1.0 was cut. Do them in order. Each says what nobody had seen work.

1. **Onboarding and the hotkey.** Go through onboarding. Leave File Search on. Skip every permission. On the Hotkey step press Open Keyboard Settings and turn off Show Spotlight search. Expect the green line and the "⌘Space Now Opens Slick" HUD, then ⌘Space opens the panel with the full glass look in the first frame, no flat flash. Untested live: the onboarding window, the Keyboard settings link and its anchor, noticing the shortcut change, the Carbon hotkey, the HUD, the menu bar menu, summoning with key status.
2. **Learning and quitting.** Type "saf", pick the second result twice, then quit from the bolt menu and start Slick again. Expect your pick first for "saf". While it runs, open Slick a second time. Expect the first copy's panel to open and no second bolt. Untested live: the 5 second quit, the engine's files in your data folder, the lock file and the second copy.
3. **A paste.** Open TextEdit, summon, type ":thumbs" and press Return. Expect the Accessibility card. Press its button, allow Slick in System Settings, come back and run it again. Expect 👍 in TextEdit. Untested live: macOS's own Accessibility dialog, the HUD over System Settings, the "Run Again" toast, the Command-V Slick sends, and waiting for TextEdit to take key focus.
4. **Clipboard history.** In Settings, Features, turn on Clipboard History. Copy a line of text in TextEdit. Open Clipboard History and use Allow Access if it asks. Pick the line and paste it. Untested live: the 4 times a second clipboard check, the Paste from Other Apps setting, pasting from history.
5. **Snippet expansion.** Create a snippet with the keyword `;sig`, turn on keyword expansion, allow Input Monitoring and Accessibility, then type `;sig` in TextEdit. Expect the text to replace the keyword. Untested live: the keyboard event tap and typed replacement.
6. **Windows and menus.** With a TextEdit window in front, run Left Half, then Switch Windows, then Search Menu Items and pick Format, then a menu item. Untested live: moving real windows, listing them, reading and pressing a real app's menus.
7. **System commands.** Run Toggle Dark Mode twice, and allow System Events when macOS asks. The panel's glyphs should follow each switch. Run Lock Screen. Run Restart and press Cancel on Slick's card. Run Empty Trash only if nothing in your Trash matters. Untested live: Apple Events to System Events, Finder and the login window, the lock call and the Trash.
8. **Files.** Search for a file you know in your home folder. In Choose Folders to Search include Documents and allow it. Type `~/` and press Tab to walk into a folder, and type `/Applications/`. Quit, start again, and expect search to work at once without a long rebuild. Untested live: walking your home folder, the folder prompts, listing a folder outside the index, resuming from saved file system events.
9. **Calendar, contacts and words.** Run My Schedule and allow Calendars. If a meeting with a link starts soon, its Join row shows before you type. Run Search Contacts and allow Contacts, then pick a person and copy an email. Type "define serendipity". In Search Bookmarks, choose Chrome or Firefox if you use one. Untested live: EventKit, Contacts, the Mac's own dictionaries and reading a browser's bookmark file.
10. **Network and themes.** Type "100 usd in eur" and wait for the answer to fill in. Run Ask AI with the Apple on-device model and ask one question. Press Escape while it streams, then summon again. In Settings, Appearance, pick Beam, then Clear, then the theme you want to keep. In Settings, General, turn on "Open at login", then turn it off. In a release, look at Updates in the same pane: it shows the switch, the time of the last check and Check Now. Untested live: the exchange rate download, the on-device model, an answer that streams while the panel is hidden, the login item, the themes on a real desktop, and Sparkle's updater.

## If something fails

Open an issue on the repository with:

1. Which of the ten steps, and the exact words on the card, toast or HUD, or a screenshot of the panel.
2. The time it happened.
3. The launcher's log from around that time. In Terminal:

   ```sh
   log show --last 10m --info --predicate 'subsystem == "com.shawnschwartz.slick"'
   ```

   Read it before you post it. It names commands and features, and it should hold no text you typed, but check.
4. Whether the bolt menu shows a problem line, and whether quitting and starting again changed anything.
5. For a permission problem, what System Settings, Privacy and Security shows for Slick under that permission.

Report a security problem privately, as [SECURITY.md](../SECURITY.md) says, not in an issue.

To start over from nothing: quit Slick, move `~/Library/Application Support/Slick` to the Trash, and clear its settings with `defaults delete com.shawnschwartz.slick`. Onboarding then shows again. Permissions you granted stay with the app until you remove them in System Settings.
