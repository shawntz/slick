# Changelog

Changes that people will notice go under `## Unreleased` as they land. To release, rename that
heading to the version, such as `## 0.1.0`, and start a new, empty `## Unreleased` above it.
[docs/RELEASING.md](docs/RELEASING.md) has the steps. Versions are `X.Y.Z`.

## Unreleased

The first release. It needs macOS 26 or later on Apple silicon.

### Added

- Liquid Glass panel: a real system glass panel, not a blur imitation, with a selection lens that
  glides between rows.
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

Features still in progress, such as file search, snippets and window management, are not listed here.
Some of them already appear in the app and may not work fully yet. The feature list in the README
says how far along each one is.
