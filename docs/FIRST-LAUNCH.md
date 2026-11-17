# Your first launch

This page is for anyone who starts Slick on a Mac for the first time. It covers the build with twenty-one features.

The live launcher first ran on a real Mac on 16 November 2026, when its owner walked through onboarding. Before that, every test, scenario, selftest and benchmark ran in a temporary folder, against made-up apps, files, contacts, calendars, songs and translations. Most features still have not run on a real Mac. The last section lists the live paths that have never run.

## How to start it

From a release:

1. Install it with `brew install --cask shawntz/tap/slick`, or download the zip from the latest release on GitHub and move Slick to Applications.
2. Open Slick from Applications.

From a checkout:

1. Make sure no `make bench`, `make scenario` or `make selftest` run is going. If one runs, macOS may bring that copy forward instead of starting yours.
2. Run `make run`. It builds the release app into build/Slick.app and opens it through LaunchServices.

To quit, choose Quit in the bolt menu in the menu bar. Quitting waits up to 5 seconds while the launcher saves what it learned and stops any shell command that still runs.

Your data goes to `~/Library/Application Support/Slick`. Settings go to the app's own preferences file. Nothing leaves the Mac unless you ask for something that needs the network, such as a web search, a currency conversion, an AI provider you set up, or a shell command you run, or unless you agree to update checks.

## What appears, in order

1. No Dock icon. A bolt appears in the menu bar at once.
2. The onboarding window opens in front at the same moment.
3. On a new Mac, ⌘Space opens Spotlight, so the launcher hotkey waits. Nothing is bound and no error shows. Slick changes no system setting at launch. The bolt menu has a Turn Off Spotlight's Shortcut item. Until the hotkey is bound, Open in that menu opens the launcher.
4. In the background, with no prompt, the twenty-one features register and nineteen of them turn on. Clipboard History and File Search start off.

While they turn on, the five new features do this and nothing more:

- Shell Commands reads its history file, which does not exist yet.
- Notes makes an empty `Notes` folder in its data folder, lists it and watches it for changes.
- Colors reads its history file, which does not exist yet.
- Translate asks macOS which languages it can translate and which languages you prefer. This is a call into Apple's Translation framework, and it runs at every launch before you do anything. It translates nothing and downloads nothing.
- Media Controls does nothing until you run one of its commands or its Play or Pause row shows.

Onboarding, step by step:

1. **Welcome.** It says "Press your hotkey and start typing. Slick finds the app, file, setting or command you mean. Press Return to open it." and "Slick remembers what you pick and shows it first next time. What it learns stays on this Mac." The button is Get Started.
2. **Hotkey.** The recorder shows ⌘Space. When Spotlight's shortcut uses ⌘Space, the step says "⌘Space opens Spotlight right now. When you press Continue, Slick turns off Spotlight's shortcut. Then ⌘Space opens Slick." Press Continue, and Slick turns off Show Spotlight search for you, binds ⌘Space and moves to the next step. A message on screen says "⌘Space Now Opens Slick". To keep ⌘Space for Spotlight, record another hotkey before you continue. When another macOS shortcut uses your keys, the step says to turn it off in System Settings, under Keyboard, and Slick waits for it.
3. **Optional Features.** Clipboard History, off, and File Search, whose switch starts on because onboarding suggests it. The switches take effect when you press Continue.
4. **Permissions.** One row per permission that the features you kept on can need, with each feature's reason, and Skip and Allow buttons. A reason reads like "Calculator uses it to paste answers into the frontmost app." The rows sit under four headings, Typing and Pasting, Files and Folders, Calendar and Contacts, and Other Apps. Full Disk Access comes first under Files and Folders, because allowing it also allows the folders below it except iCloud Drive. Slick asks macOS nothing until you press Allow. With File Search left on there are seventeen rows, and eleven without it. You can skip every row. Each feature asks again, through a card in the panel, the first time you run something that needs it. If macOS gives no answer within 5 seconds of Allow, as can happen for iCloud Drive, the row says "macOS has not answered yet. You can allow it in System Settings, under Privacy & Security, Files & Folders." and offers Open System Settings. An answer that comes later still turns the row to Allowed.
5. **Theme.** The seven built-in themes, among them Spotlight and Glass, each in a tile of the same size. Picking one applies it.
6. **Done.** How to open the launcher, and "Type to search. Press Return to open the top result. Press Command-K to see what else you can do with it. Press Command-comma to open Settings." In a release, this step also has a switch, Check for Updates Automatically, that starts on. Slick stores your choice when you press Start, and checks nothing before that.

Two rows on the Permissions step are new. They are titled Music Automation and Spotify Automation. A player that is not installed is titled Automation. While that app is not open, the row has no button and says "macOS asks the first time you control Music while it is open." For a player that is not installed, it says "this app" in place of the name. Only a player that is open when you look gets an Allow button.

If you close the onboarding window, it opens again at the next launch. Switches you did not continue past are not applied.

When the hotkey's keys become free, Slick binds them and a HUD says "⌘Space Now Opens Slick". While another macOS shortcut uses the keys, the launcher checks every 2 seconds for 10 minutes, then every 30 seconds, and at once whenever the settings or onboarding window opens.

## Every permission, and when it is asked

Slick asks for no permission at launch. It asks for each one only after you press Allow in onboarding, Allow in the Permissions pane of settings, or Grant Access on the panel's permission card. The card shows the first time you run something that needs it. The card's title names the feature and the permission, such as "Media Controls Needs Automation".

For a permission that only System Settings can grant, the panel closes, a HUD says what to allow, and Slick opens that pane unless macOS showed its own dialog. A grant made in System Settings does not run the waiting command. A toast such as "Accessibility Allowed, Run Paste Snippet Again" asks you to run it again.

| Feature | On at first launch | Permission | What it unlocks, and when it is asked |
|---|---|---|---|
| Apps | yes | none | |
| Clipboard History | no | Paste from Other Apps | reading what other apps copy. Asked when you turn the feature on and its history page shows Allow Access. macOS 27.2 has no request for it, so Slick opens System Settings |
| Clipboard History | no | Accessibility | pasting an entry into another app |
| Snippets | yes | Accessibility | pasting a snippet, and Fill In Snippet |
| Snippets | yes | Input Monitoring and Accessibility | keyword expansion as you type in other apps. Asked when you turn it on |
| Quicklinks | yes | Accessibility | only for a quicklink that uses `{selection}` |
| Emoji | yes | Accessibility | Return pasting an emoji into the app you were using |
| Window Management | yes | Accessibility | the first window command, and Switch Windows |
| System | yes | Automation of Finder | Empty Trash |
| System | yes | Automation of System Events | Toggle Dark Mode. Allow starts System Events hidden to ask, because it is a helper with no window |
| System | yes | Automation of the login window | Log Out, Restart and Shut Down |
| Script Commands | yes | Accessibility | pasting a list script's result. Your scripts run as you and may raise their own prompts, which name Slick |
| Calculator | yes | Accessibility | only pasting an answer. Return copies, which needs nothing |
| File Search | no | Desktop, Documents, Downloads, iCloud Drive, removable volumes, network volumes | indexing the names of the files in that place. Asked when you include it in Choose Folders to Search. Each has its own prompt, and Full Disk Access spares all but iCloud Drive |
| File Search | no | Full Disk Access | optional, from the same place. macOS has no request, so Slick opens System Settings |
| Dictionary | yes | Accessibility | only pasting a definition or a word |
| Calendar and Reminders | yes | Calendars | My Schedule, Create Event, and the meeting suggestion before you type |
| Calendar and Reminders | yes | Reminders | My Reminders and Create Reminder |
| Contacts | yes | Contacts | Search Contacts, and contacts in root search |
| Browser Bookmarks | yes | Full Disk Access | only if you choose Safari. Other browsers need nothing, and no browser is read until you choose one |
| AI | yes | Accessibility | reading the text you selected in another app, and pasting an answer |
| AI | yes | Local Network | macOS asks by itself the first time Slick connects to a model server on another machine on your network |
| Menu Items | yes | Accessibility | Search Menu Items |
| Shell Commands | yes | Accessibility | only Paste Output. Running a command needs nothing |
| Notes | yes | Accessibility | only Paste Note |
| Notes | yes | the folder's own prompt | only if you choose a notes folder in Desktop, Documents, Downloads, iCloud Drive or on another volume. macOS asks right after you choose it |
| Colors | yes | Accessibility | only pasting a color. Pick Color needs no permission |
| Translate | yes | Accessibility | Translate Selection, which reads the text selected in the app in front, and Paste Translation |
| Media Controls | yes | Automation of Music | play, pause, skip and Now Playing in Music. Asked from the card the first time you run a media command while Music is open, or from Allow in Media Controls' settings while Music is open |
| Media Controls | yes | Automation of Spotify | the same for Spotify, while Spotify is open |

Nothing asks for an app that is not open, and nothing starts Music or Spotify to ask. If no player is open, a media command asks "Open Music?" and opens it only if you press Open Music.

Slick starts a shell command or script you run, so macOS asks on Slick's behalf. A command that reads Desktop or Documents shows the folder prompt with Slick's name. A command that controls another app shows the Automation prompt. A command that reaches another machine on your network can show the Local Network prompt. A command that records the screen shows the Screen Recording prompt. Slick has no usage text for the camera, the microphone or Bluetooth, so a command that needs one of those is likely refused without a prompt. Run such a command in Terminal instead, with Open in Terminal. A command also has every permission you gave Slick, such as Accessibility and Full Disk Access, with no prompt. Shell Commands' settings say both.

No feature of its own uses Location, the camera, the microphone, Screen Recording or Focus. The app's property list has a plain sentence for every permission above. The release entitlements grant Apple Events, Contacts and Calendars and nothing else.

macOS ties a grant to the app's signature. A release asks again for what a build from a checkout already had.

## What is off until you switch it on

- Clipboard History and File Search. File Search's switch starts on in onboarding.
- Snippets' keyword expansion.
- Note titles in root search. Quick capture with `note` is on.
- Every fallback row under a search, except the default web searches. Translate's fallback starts off.
- Web icons for script commands.
- Open at login.
- Every hotkey preset. Window Management and Media Controls offer presets, and nothing is bound until you review one and press Apply.
- Any AI provider other than Apple's on-device model, which is the default.

Shell Commands is on. Nothing runs until you type `>`, a command and press Return. `>` alone shows a hint that runs nothing.

## What Slick reads and stores at first launch, with no action from you

Reads:

- The apps in /Applications, /System/Applications, /System/Library/CoreServices/Applications and ~/Applications. Slick reads each app's Info.plist and name, and its icon for the icon cache. It watches those folders for changes.
- The System Settings panes and their search terms, from the system's own extensions.
- On the first launch only, the apps in your Dock, the apps that run now, and Spotlight's use counts for apps in the system's app folders. Learning starts from them as light priors. No prompt.
- The status of each permission, through calls that never prompt. For Music and Spotify the check gets an answer only while that app is open, and it never starts the app.
- The Time Machine settings file, then the Mail and Messages library folders, to find out whether Full Disk Access is on. Without Full Disk Access macOS refuses these reads quietly. Slick reads nothing in them.
- The front app, power source, displays and audio output, for suggestions before you type. Focus is never read.
- The macOS shortcuts and the keys each one uses, to know whether Spotlight's shortcut uses ⌘Space. Slick changes none of them at launch.
- The system's time zone files, for the calculator.
- The list of languages the Mac can translate, and your preferred languages, from macOS.
- Its own empty notes folder.
- Nothing from your browsers, contacts, calendars, clipboard, music apps or documents.

If you leave File Search's switch on in onboarding and press Continue, it starts indexing the names of the files in your home folder in the background. It skips Library, every package such as an app or a photo library, and Desktop, Documents, Downloads and iCloud Drive until you include them. It reads names and dates, never contents.

Stores, all under `~/Library/Application Support/Slick`:

- `launcher.lock`, which marks the one running copy.
- `app.root`, which holds what the launcher learns, as a snapshot and an event log.
- `Features/<feature>`, which holds each feature's own files, such as `snippets.json`, `quicklinks.json`, the script folder and AI chats. The clipboard history database appears only once Clipboard History is on.
- `Features/notes/Notes`, an empty folder at first. Each note you save is a Markdown file there.
- `Caches`, which holds the icon atlas.
- `Themes`, which holds your own theme files and your changes to the built-in themes.

Later, as you use the new features:

- `Features/shell/history.json` keeps up to 200 commands you ran. A command typed with two spaces after `>` is never kept, and Keep history in settings turns saving off. The `Features/shell` folder is left out of Time Machine backups, and Clear History also deletes any damaged history file set aside there.
- `Caches/shell/Terminal` holds a script for Open in Terminal until Terminal starts it. The script deletes itself then. The next Open in Terminal deletes one that Terminal never started, once it is ten minutes old.
- `Features/notes/pins.json` keeps which notes you pinned.
- `Features/colors/history.json` keeps up to 100 colors you picked or copied. Pinned colors are always kept.
- Translate and Media Controls keep only their settings.

Slick's own code makes no network request at launch. The first request happens when you search the web, convert a currency, ask an AI provider you set up, turn on web icons for scripts, or run a shell command that uses the network. Translate's language list comes from macOS. Whether macOS itself goes online to answer it has not been checked. In a release, once Check for Updates Automatically is on, Slick also asks GitHub once a day whether a newer version exists. That request carries the version numbers of Slick and its updater and, like any web request, your IP address. A build from a checkout has no updater.

## What happens when you quit

- Every shell command still running gets SIGTERM, and SIGKILL half a second later if it is still there. This reaches every process the command started. A command still running at quit may not reach Shell History.
- Slick writes Notes, Colors and Shell History whole or not at all, so a quit never leaves half a file.
- Translate stops loading its language list, and Media Controls stops nothing, because it keeps nothing running.
- The launcher saves what it learned, releases `launcher.lock` and quits within 5 seconds.

## Try each feature safely

Do these in order. Each one says what nobody has seen work yet. Skip a feature you do not want to touch.

### The core

1. **Onboarding and the hotkey.** Go through onboarding, leave File Search on and skip every permission. On the Hotkey step, press Continue. Expect the "⌘Space Now Opens Slick" HUD, and Show Spotlight search turned off in System Settings, under Keyboard, Keyboard Shortcuts, Spotlight. Then ⌘Space opens the panel with the full glass look in the first frame. The onboarding window, the switch that turns off Spotlight's shortcut, the Carbon hotkey, the HUD and the menu bar menu have never run live.
2. **Learning and quitting.** Type "saf", pick the second result twice, quit from the bolt menu and start Slick again. Expect your pick first for "saf". While it runs, open Slick a second time, and expect the first copy's panel to open and no second bolt. The 5 second quit, the engine's files, the lock file and the second copy have never run live.

The panel reached the screen in about 26 ms, and 47 ms at worst, measured inside the app bundle with sixteen features. The five new features add four root search answers that look at every keystroke, for `>`, `note`, colors and `tr`. They have not been measured in the app.

### The sixteen earlier features

3. **Apps.** Type part of an app's name and press Return to open it. Reading your app folders and their icons has never run live.
4. **Clipboard History.** In Settings, Features, turn it on. Copy a line in TextEdit, open Clipboard History, use Allow Access if it asks, then paste the line back. The 4 times a second clipboard check, the Paste from Other Apps setting and pasting from history have never run live.
5. **Snippets.** Create a snippet with the keyword `;sig` and paste it into TextEdit, which asks for Accessibility. Then turn on keyword expansion, allow Input Monitoring and Accessibility, and type `;sig`. The paste, the keyboard event tap and the typed replacement have never run live.
6. **Quicklinks.** Type a few words that match nothing local and pick a web search at the bottom. Expect your default browser to open. Opening a link in your browser has never run live.
7. **Emoji.** Open TextEdit, summon, type ":thumbs" and press Return. Expect the Accessibility card, then 👍 in TextEdit once you allow it and run it again. macOS's own Accessibility dialog, the "Run Again" toast and the Command-V Slick sends have never run live.
8. **Window Management.** With a TextEdit window in front, run Left Half, then Switch Windows. Moving and listing real windows has never run live.
9. **System.** Run Toggle Dark Mode twice and allow System Events when macOS asks. Run Lock Screen. Run Restart and press Cancel on Slick's card. Run Empty Trash only if nothing in your Trash matters. Apple Events to System Events, Finder and the login window, and the lock call have never run live.
10. **Script Commands.** Run Create Script Command, make a script that prints a line, and run it. Your script runs as you. A real script through the process runner has never run live.
11. **Calculator.** Type "100 usd in eur" and wait for the answer to fill in, then press Return to copy it. The exchange rate download has never run live.
12. **File Search.** Search for a file you know in your home folder. In Choose Folders to Search include Documents and allow it. Type `~/` and press Tab to walk into a folder. Quit, start again, and expect search to work at once. Walking your home folder, the folder prompts and resuming from saved file system events have never run live.
13. **Dictionary.** Type "define serendipity". Reading the Mac's own dictionaries has never run live.
14. **Calendar and Reminders.** Run My Schedule and allow Calendars. If a meeting with a link starts soon, its Join row shows before you type. EventKit has never run live.
15. **Contacts.** Run Search Contacts and allow Contacts, then pick a person and copy an email. The Contacts framework has never run live.
16. **Browser Bookmarks.** In Search Bookmarks, choose Chrome or Firefox if you use one. Choosing Safari needs Full Disk Access. Reading a browser's bookmark file has never run live.
17. **AI.** Run Ask AI with Apple's on-device model and ask one question. Press Escape while it streams, then summon again. The on-device model, and an answer that streams while the panel is hidden, have never run live.
18. **Menu Items.** With TextEdit in front, run Search Menu Items, pick Format, then a menu item. Reading and pressing a real app's menus has never run live.

### The five new features

19. **Shell Commands.** Type `> echo hello`, press Return, and expect its output with "Exited with status 0", then run `> sleep 30` and press Control-C to see "Stopped". The command runs with your rights in your login shell, which reads `.zprofile` but not `.zshrc`, so keep to harmless commands and stay out of Desktop and Documents at first. A pasted command with more than three spaces in a row between its words, or with a character that draws as a blank, shows a red row that says why and does not run. Finding your login shell, starting a real shell, Stop on a real process group, quitting while a command runs, and Open in Terminal have never run live.
20. **Notes.** Type `note buy oat milk`, press Return for the HUD "Saved Note", find it with Search Notes, and use Show in Finder in its settings to see the Markdown file. Keep the default folder at first, because a folder in Documents makes macOS ask right after you choose it. The folder watch, a folder macOS guards, and the folders-only Choose Folder dialog have never run live.
21. **Colors.** Type `#1e90ff` and press Return to copy "#1E90FF". Then run Pick Color and click a pixel in the system's magnifier, or press Escape to change nothing. The system color sampler has never run live.
22. **Translate.** Type `tr bonjour`, and with French and English installed the row fills with the translation. Otherwise it says "Download French to Translate", and Return only opens Translation Languages in System Settings, where you can leave without downloading. The language list at launch, translating with Apple's framework, and Translate Selection have never run live.
23. **Media Controls.** With Music and Spotify closed, run Play or Pause and press Cancel on "Open Music?", which opens nothing. Then open Music, run it again, press Grant Access on the card and Allow when macOS asks, and expect a HUD that says what Music does now. Pause Music, type `pause` and press Return. Expect "Music Is Already Paused", and Music stays paused. The running-apps check, the Apple Events to Music and Spotify, and the permission request have never run live.

Last, in Settings, Appearance, pick Spotlight, then Glass, then the theme you want to keep. In Settings, General, turn on Open at login, then turn it off. In a release, look at Updates in the same pane. It shows the switch, the time of the last check and Check Now. The login item, the themes on a real desktop, and Sparkle's updater have never run live.

## Live paths nobody has run yet

Most of the launcher's live mode is untried. Onboarding has been walked once, on 16 November 2026. These paths carry the most risk, because no test can reach them:

- The onboarding window, the Keyboard settings link, the Carbon hotkey, summoning with key status, the menu bar menu and the HUDs.
- Every permission request, the 5 second limit on a request macOS leaves unanswered, and the System Settings panes they open.
- The switch that turns off Spotlight's shortcut. It writes `com.apple.symbolichotkeys`, then calls `CGSSetSymbolicHotKeyEnabled` or runs `activateSettings`. The General pane's offer to turn the shortcut back on has never run either.
- Pasting into another app, the clipboard check, the keyboard event tap and typed replacement.
- Moving real windows, reading real menus, the lock call, and Apple Events to Finder, System Events and the login window.
- Walking your home folder, the folder prompts, the bookmark files, EventKit, Contacts and the Mac's dictionaries.
- The exchange rate download, the on-device model, the login item, the themes on a real desktop, and Sparkle's updater.
- A real script or shell command through the process runner, Stop on a real process group, and stopping every command when the app quits.
- Shell's login shell lookup, its environment, and Open in Terminal.
- Notes on a folder macOS guards, its folder watch, and its folders-only dialog.
- The system color sampler.
- Translate's language list at launch, translating with Apple's framework, and opening Translation Languages.
- Media Controls' running-apps check, its Apple Events to Music and Spotify, including the new pause event, the Automation request while a player is open, and opening a player.
- Asking for Automation in settings, with no button for a player that is closed, and System Events started hidden to ask.

## If something fails

Open an issue on the repository with:

1. Which step, and the exact words on the card, toast or HUD, or a screenshot of the panel.
2. The time it happened.
3. The launcher's log from around that time. In Terminal:

   ```sh
   log show --last 10m --info --predicate 'subsystem == "com.shawnschwartz.slick"'
   ```

   Read it before you post it.
4. Whether the bolt menu shows a problem line, and whether quitting and starting again changed anything.
5. For a permission problem, what System Settings, Privacy and Security shows for Slick under that permission.

The log never holds a shell command, its output, a note or a translation.

Report a security problem privately, as [SECURITY.md](../SECURITY.md) says, not in an issue.

## To start over

Quit Slick from the bolt menu and move `~/Library/Application Support/Slick` to the Trash. Then clear its settings, which live in the app's own preferences domain:

`defaults delete com.shawnschwartz.slick`

Onboarding then shows again. Permissions you granted stay with the app until you remove them in System Settings. If Slick turned off Spotlight's shortcut, it stays off. To turn it on, open Keyboard in System Settings, click Keyboard Shortcuts, then Spotlight, and turn on Show Spotlight search. Notes you saved in a folder of your own choosing stay there.
