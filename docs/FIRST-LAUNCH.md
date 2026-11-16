# Your first launch

This page is for the owner, before Slick starts on a Mac for the first time. It covers the build with twenty-one features: the sixteen of the earlier guide, plus Shell Commands, Notes, Colors, Translate and Media Controls.

As far as the project's records show, nobody has started the live launcher yet. Every test, scenario, selftest and benchmark ran in a temporary folder, against made-up apps, files, contacts, calendars, songs and translations. This launch is the first time the code meets your Mac. The last section lists every live path that has never run.

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
3. Spotlight holds Command-Space on a new Mac, so the launcher hotkey waits. Nothing is bound and no error shows. The bolt menu starts with "Spotlight Holds ⌘Space" and an Open Keyboard Settings item, above Open, Settings and Quit. Until the hotkey is free, Open in that menu opens the launcher.
4. In the background, with no prompt, the twenty-one features register and nineteen of them turn on. Clipboard History and File Search start off.

While they turn on, the five new features do this and nothing more:

- Shell Commands reads its history file, which does not exist yet.
- Notes makes an empty `Notes` folder in its data folder, lists it and watches it for changes.
- Colors reads its history file, which does not exist yet.
- Translate asks macOS which languages it can translate and which languages you prefer. This is a call into Apple's Translation framework, and it runs at every launch before you do anything. It translates nothing and downloads nothing.
- Media Controls does nothing until you run one of its commands or its Play or Pause row shows.

Onboarding, step by step:

1. **Welcome.** What the launcher is, and that learning stays on the Mac. Button: Get Started.
2. **Hotkey.** The recorder shows ⌘Space. While Spotlight holds it, the step shows three steps in the system's own words to turn off Spotlight's shortcut, an Open Keyboard Settings button, and a waiting line that turns green the moment ⌘Space is free. You may record another hotkey instead.
3. **Optional Features.** Clipboard History, off, and File Search, whose switch starts on because it is suggested. The switches take effect when you press Continue.
4. **Permissions.** One row per permission that the features you kept on can need, with each feature's reason, and Skip and Allow buttons. Nothing is asked of macOS until you press Allow. With File Search left on there are seventeen rows, and eleven without it. You can skip every row. Each feature asks again, through a card in the panel, the first time you run something that needs it.
5. **Theme.** The seven built-in themes, among them Beam and Clear. Picking one applies it.
6. **Done.** How to open the launcher. In a release, this step also has a switch, Check for Updates Automatically, that starts on. Slick stores your choice when you press Start, and checks nothing before that.

Two rows on the Permissions step are new. Both are titled Automation, and their reasons name Music and Spotify. While that app is not open, the row has no button and says "macOS asks the first time you control Music while it is open." For a player that is not installed, it says "this app" in place of the name. Only a player that is open when you look gets an Allow button.

Closing the onboarding window with its close button means onboarding opens again at the next launch, and switches you did not continue past are not applied.

When ⌘Space becomes free, a HUD says "⌘Space Now Opens Slick". The launcher checks every 2 seconds for 10 minutes, then every 30 seconds, and at once whenever the settings or onboarding window opens.

## Every permission, and when it is asked

No permission is asked at launch. Each one is asked only after you press a button: Allow in onboarding, Allow in the Permissions pane of settings, or Grant Access on the panel's permission card, which shows the first time you run something that needs it. The card is titled with the feature and the permission, such as "Media Controls Needs Automation".

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

A shell command or script you run is started by Slick, so macOS asks on Slick's behalf. A command that reads Desktop or Documents shows the folder prompt with Slick's name. A command that controls another app shows the Automation prompt. A command that reaches another machine on your network can show the Local Network prompt. A command that records the screen shows the Screen Recording prompt. Slick has no usage text for the camera, the microphone or Bluetooth, so a command that needs one of those is likely refused without a prompt. Run such a command in Terminal instead, with Open in Terminal. A command also has every permission you gave Slick, such as Accessibility and Full Disk Access, with no prompt. Shell Commands' settings say both.

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

- The apps in /Applications, /System/Applications, /System/Library/CoreServices/Applications and ~/Applications: each app's Info.plist and name, and its icon for the icon cache. It watches those folders for changes.
- The System Settings panes and their search terms, from the system's own extensions.
- On the first launch only, for light learning priors: the apps in your Dock, the apps that run now, and Spotlight's use counts for apps in the system's app folders. No prompt.
- The status of each permission, through calls that never prompt. For Music and Spotify the check gets an answer only while that app is open, and it never starts the app.
- To find out whether Full Disk Access is on: the Time Machine settings file, then the Mail and Messages library folders. Without Full Disk Access macOS refuses these reads quietly. Slick reads nothing in them.
- The front app, power source, displays and audio output, for suggestions before you type. Focus is never read.
- The macOS shortcuts that hold key combinations, to know whether Spotlight holds ⌘Space.
- The system's time zone files, for the calculator.
- The list of languages the Mac can translate, and your preferred languages, from macOS.
- Its own empty notes folder.
- Nothing from your browsers, contacts, calendars, clipboard, music apps or documents.

If you leave File Search's switch on in onboarding and press Continue, it starts indexing the names of the files in your home folder in the background. It skips Library, every package such as an app or a photo library, and Desktop, Documents, Downloads and iCloud Drive until you include them. It reads names and dates, never contents.

Stores, all under `~/Library/Application Support/Slick`:

- `launcher.lock`, which marks the one running copy.
- `app.root`: what the launcher learns, as a snapshot and an event log.
- `Features/<feature>`: each feature's own files, such as `snippets.json`, `quicklinks.json`, the script folder and AI chats. The clipboard history database appears only once Clipboard History is on.
- `Features/notes/Notes`: an empty folder at first. Each note you save is a Markdown file there.
- `Caches`: the icon atlas.
- `Themes`: your own theme files.

Later, as you use the new features:

- `Features/shell/history.json` keeps up to 200 commands you ran. A command typed with two spaces after `>` is never kept, and Keep history in settings turns saving off. The `Features/shell` folder is left out of Time Machine backups, and Clear History also deletes any damaged history file set aside there.
- `Caches/shell/Terminal` holds a script for Open in Terminal until Terminal starts it. The script deletes itself then. One that Terminal never started is deleted by the next Open in Terminal once it is ten minutes old.
- `Features/notes/pins.json` keeps which notes you pinned.
- `Features/colors/history.json` keeps up to 100 colors you picked or copied. Pinned colors are always kept.
- Translate and Media Controls keep only their settings.

Network: none at launch from Slick's own code. The first request happens when you search the web, convert a currency, ask an AI provider you set up, turn on web icons for scripts, or run a shell command that uses the network. Translate's language list comes from macOS. Whether macOS itself goes online to answer it has not been checked. In a release, once Check for Updates Automatically is on, Slick also asks GitHub once a day whether a newer version exists. That request carries the version numbers of Slick and its updater and, like any web request, your IP address. A build from a checkout has no updater.

## What happens when you quit

- Every shell command still running gets SIGTERM, and SIGKILL half a second later if it is still there. This reaches every process the command started. A command still running at quit may not reach Shell History.
- Notes, Colors and Shell History are written whole or not at all, so a quit never leaves half a file.
- Translate stops loading its language list, and Media Controls stops nothing, because it keeps nothing running.
- The launcher saves what it learned, releases `launcher.lock` and quits within 5 seconds.

## Try each feature safely

Do these in order. Each one says what nobody has seen work yet. Skip a feature you do not want to touch.

### The core

1. **Onboarding and the hotkey.** Go through onboarding, leave File Search on and skip every permission. On the Hotkey step press Open Keyboard Settings and turn off Show Spotlight search. Expect the green line and the "⌘Space Now Opens Slick" HUD, then ⌘Space opens the panel with the full glass look in the first frame. Never run live: the onboarding window, the Keyboard settings link, noticing the shortcut change, the Carbon hotkey, the HUD and the menu bar menu.
2. **Learning and quitting.** Type "saf", pick the second result twice, quit from the bolt menu and start Slick again. Expect your pick first for "saf". While it runs, open Slick a second time, and expect the first copy's panel to open and no second bolt. Never run live: the 5 second quit, the engine's files, the lock file and the second copy.

The panel reached the screen in about 26 ms, and 47 ms at worst, measured inside the app bundle with sixteen features. The five new features add four root search answers that look at every keystroke, for `>`, `note`, colors and `tr`. They have not been measured in the app.

### The sixteen earlier features

3. **Apps.** Type part of an app's name and press Return to open it. Never run live: reading your app folders and their icons.
4. **Clipboard History.** In Settings, Features, turn it on. Copy a line in TextEdit, open Clipboard History, use Allow Access if it asks, then paste the line back. Never run live: the 4 times a second clipboard check, the Paste from Other Apps setting and pasting from history.
5. **Snippets.** Create a snippet with the keyword `;sig` and paste it into TextEdit, which asks for Accessibility. Then turn on keyword expansion, allow Input Monitoring and Accessibility, and type `;sig`. Never run live: the paste, the keyboard event tap and the typed replacement.
6. **Quicklinks.** Type a few words that match nothing local and pick a web search at the bottom. Expect your default browser to open. Never run live: opening a link in your browser.
7. **Emoji.** Open TextEdit, summon, type ":thumbs" and press Return. Expect the Accessibility card, then 👍 in TextEdit once you allow it and run it again. Never run live: macOS's own Accessibility dialog, the "Run Again" toast and the Command-V Slick sends.
8. **Window Management.** With a TextEdit window in front, run Left Half, then Switch Windows. Never run live: moving and listing real windows.
9. **System.** Run Toggle Dark Mode twice and allow System Events when macOS asks. Run Lock Screen. Run Restart and press Cancel on Slick's card. Run Empty Trash only if nothing in your Trash matters. Never run live: Apple Events to System Events, Finder and the login window, and the lock call.
10. **Script Commands.** Run Create Script Command, make a script that prints a line, and run it. Your script runs as you. Never run live: a real script through the process runner.
11. **Calculator.** Type "100 usd in eur" and wait for the answer to fill in, then press Return to copy it. Never run live: the exchange rate download.
12. **File Search.** Search for a file you know in your home folder. In Choose Folders to Search include Documents and allow it. Type `~/` and press Tab to walk into a folder. Quit, start again, and expect search to work at once. Never run live: walking your home folder, the folder prompts and resuming from saved file system events.
13. **Dictionary.** Type "define serendipity". Never run live: the Mac's own dictionaries.
14. **Calendar and Reminders.** Run My Schedule and allow Calendars. If a meeting with a link starts soon, its Join row shows before you type. Never run live: EventKit.
15. **Contacts.** Run Search Contacts and allow Contacts, then pick a person and copy an email. Never run live: the Contacts framework.
16. **Browser Bookmarks.** In Search Bookmarks, choose Chrome or Firefox if you use one. Choosing Safari needs Full Disk Access. Never run live: reading a browser's bookmark file.
17. **AI.** Run Ask AI with Apple's on-device model and ask one question. Press Escape while it streams, then summon again. Never run live: the on-device model, and an answer that streams while the panel is hidden.
18. **Menu Items.** With TextEdit in front, run Search Menu Items, pick Format, then a menu item. Never run live: reading and pressing a real app's menus.

### The five new features

19. **Shell Commands.** Type `> echo hello`, press Return, and expect its output with "Exited with status 0", then run `> sleep 30` and press Control-C to see "Stopped". The command runs with your rights in your login shell, which reads `.zprofile` but not `.zshrc`, so keep to harmless commands and stay out of Desktop and Documents at first. A pasted command with more than three spaces in a row between its words, or with a character that draws as a blank, shows a red row that says why and does not run. Never run live: finding your login shell, starting a real shell, Stop on a real process group, quitting while a command runs, and Open in Terminal.
20. **Notes.** Type `note buy oat milk`, press Return for the HUD "Saved Note", find it with Search Notes, and use Show in Finder in its settings to see the Markdown file. Keep the default folder at first, because a folder in Documents makes macOS ask right after you choose it. Never run live: the folder watch, a folder macOS guards, and the folders-only Choose Folder dialog.
21. **Colors.** Type `#1e90ff` and press Return to copy "#1E90FF". Then run Pick Color and click a pixel in the system's magnifier, or press Escape to change nothing. Never run live: the system color sampler.
22. **Translate.** Type `tr bonjour`, and with French and English installed the row fills with the translation. Otherwise it says "Download French to Translate", and Return only opens Translation Languages in System Settings, where you can leave without downloading. Never run live: the language list at launch, translating with Apple's framework, and Translate Selection.
23. **Media Controls.** With Music and Spotify closed, run Play or Pause and press Cancel on "Open Music?", which opens nothing. Then open Music, run it again, press Grant Access on the card and Allow when macOS asks, and expect a HUD that says what Music does now. Pause Music, type `pause` and press Return: expect "Music Is Already Paused", and Music stays paused. Never run live: the running-apps check, the Apple Events to Music and Spotify, and the permission request.

Last, in Settings, Appearance, pick Beam, then Clear, then the theme you want to keep. In Settings, General, turn on Open at login, then turn it off. In a release, look at Updates in the same pane: it shows the switch, the time of the last check and Check Now. Never run live: the login item, the themes on a real desktop, and Sparkle's updater.

## Live paths nobody has run yet

Everything in the launcher's live mode is untried, because nobody has started it. These paths carry the most risk, because no test can reach them:

- The onboarding window, the Keyboard settings link, the Carbon hotkey, summoning with key status, the menu bar menu and the HUDs.
- Every permission request and the System Settings panes they open.
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
- Asking for Automation in settings: no button for a player that is closed, and System Events started hidden to ask.

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

Onboarding then shows again. Permissions you granted stay with the app until you remove them in System Settings. Notes you saved in a folder of your own choosing stay there.
