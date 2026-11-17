# Changelog

Changes that people will notice go under `## Unreleased` as they land. To release, rename that
heading to the version, such as `## 0.1.0`, and start a new, empty `## Unreleased` above it.
[docs/RELEASING.md](docs/RELEASING.md) has the steps. Versions are `X.Y.Z`.

## Unreleased

## 0.1.1

Two fixes in settings, and a choice of light or dark for the launcher.

### Added

- Light or dark launcher: in settings, under Appearance, choose Match System, Light or Dark. The
  panel and its messages follow the choice.

### Fixed

- Recording a hotkey: a click on a hotkey field in settings or onboarding now starts recording
  every time, and a second click or a click anywhere else in the window stops it. Before, the
  field took one shortcut after settings opened, then ignored clicks.
- Theme changes in settings: choosing Light or Dark, moving a slider or picking a color under
  Appearance now changes the launcher, and Slick keeps the change. A change to a built-in theme
  stays until you press Reset to Default.
- Save as New Theme: typing the name of one of your own themes no longer replaces that theme.
  Slick tells you to pick another name.

## 0.1.0

The first release. It needs macOS 26 or later on Apple silicon, and it has been tested only on
macOS 27.

### Added

- Liquid Glass panel: a real system glass panel, not a blur imitation, with a selection lens that
  glides between rows.
- Built-in themes: seven looks for the panel, among them Spotlight, modeled on Spotlight in
  macOS 27, and Glass, the system's clear glass with no tint.
- Fuzzy search: an in-house matcher that understands prefixes, acronyms, camelCase, word order and
  typos.
- Learns your habits: pick a result twice for a query and it becomes the top hit. Everything it
  learns stays on your Mac.
- Suggestions before you type: ranks what you are likely to open next from the time of day, the
  app in front and what you just used.
- Apps and System Settings: open, quit, hide or reveal any app, and jump straight to a System
  Settings pane.
- Hotkeys, aliases and favorites: give any item a global hotkey or a short alias, and pin favorites
  to the top.
- Action panel: every result has more actions behind Command-K, with their own shortcuts.
- Calculator: math, percentages, units, dates and time zones, answered as you type and copied
  with Return.
- Clipboard history: search text, links, images and files you copied, and paste them back.
- Quicklinks and web search: open sites and searches with a keyword, and fall back to the web when
  nothing local matches.
- Emoji picker: search emoji and symbols by name and paste them.
- Notes: quick notes kept as Markdown files that any editor opens. Save one from root search with
  `note` and your text, search titles and text, append, pin, tag, rename and paste them.
- Takes Command-Space from Spotlight: when Spotlight's shortcut uses the keys you chose, press
  Continue on the Hotkey step, or Turn Off Spotlight's Shortcut in settings or the bolt menu, and
  Slick turns that shortcut off for you. It changes no system setting at launch.
- Updates: once you agree, Slick checks for a new version once a day and tells you when one is
  ready. It installs an update only when you choose to, and only after checking its signature.

Features still in progress are not listed here: file search, snippets, window management, shell
commands, the color picker, Translate, media controls and others. They already appear in the app
and may not work fully yet. The feature list in the README says how far along each one is.
