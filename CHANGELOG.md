# Changelog

Changes that people will notice go under `## Unreleased` as they land. To release, rename that
heading to the version, such as `## 0.1.0`, and start a new, empty `## Unreleased` above it.
[docs/RELEASING.md](docs/RELEASING.md) has the steps. Versions are `X.Y.Z`.

## Unreleased

### Added

- Notes: quick notes kept as Markdown files that any editor opens. Save one from root search with
  `note` and your text, search titles and text, append, pin, tag, rename and paste them.

### Fixed

- Settings panes weigh as much as commands in search, so a pane whose name starts with what you
  typed comes before a command whose words it only covers, as Network does for `net`.
- Tab after a query that ends in a space no longer adds the rest of a name after the space, as in
  "note s". It completes only when the name has a space there too.
- When a link opened the launcher, closing it clears the link's text and pages, so the next time
  you open it, nothing the link typed is there to run.
- A question that a feature asks goes away when you switch that feature off.

Shell commands, the color picker, Translate and media controls are still in progress and are not
listed here.

## 0.1.0

The first release. It needs macOS 26 or later on Apple silicon.

### Added

- Liquid Glass panel: a real system glass panel, not a blur imitation, with a selection lens that
  glides between rows.
- Built-in themes: seven looks for the panel, among them Beam, modeled on the search panel of
  macOS 27, and Clear, the system's clear glass with no tint.
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
- Updates: once you agree, Slick checks for a new version once a day and tells you when one is
  ready. It installs an update only when you choose to, and only after checking its signature.

Features still in progress, such as file search, snippets and window management, are not listed
here. Some of them already appear in the app and may not work fully yet. The feature list in the
README says how far along each one is.
