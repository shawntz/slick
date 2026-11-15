# Bookmarks

Searches the bookmarks of Safari, Google Chrome, Brave, Microsoft Edge, Vivaldi, Opera, Chromium and Firefox. Feature ID `bookmarks`, module `Bookmarks`.

## What it does

- **Search Bookmarks** (`cmd:bookmarks.search`) lists every bookmark of the chosen browsers with its folder path, the browser's app icon and a dropdown for one browser, one profile or Safari's Reading List. It takes an optional query and serves as a fallback.
- **Choose Bookmark Browsers** (`cmd:bookmarks.choose-browsers`) opens a form with a switch for each installed browser.
- Bookmarks join root search when the user turns that on, at most 5,000 of them, one per link.
- Actions: Open in Default Browser, Open in the browser the bookmark came from, Open With, Copy Link, Copy as Markdown Link, Copy Title, and Reload Bookmarks on the page. A setting picks which open comes first.

## Privacy

- Every browser is off at first. Activation reads nothing. The first read follows something the user did: choosing a browser, opening Search Bookmarks, or root search asking after the user turned that on.
- Safari's file sits behind Full Disk Access. The feature never asks the file service for Safari without it, and the live service refuses Safari without it too. The permission stream is open only while Safari is chosen and the access is missing.
- The live service reads `Bookmarks.plist`, each Chromium profile's `Bookmarks` and `AccountBookmarks`, and Firefox's `places.sqlite` with its log. Nothing else: no `Local State`, no `profiles.ini`, no history or cookies. Profiles are named by their folders.
- Firefox is read through a clone in the feature's cache folder, deleted at once, so its own files are never opened with SQLite and a running Firefox is not disturbed. Only the bookmark tables are copied out of the clone. The clone holds the whole history, so each read first deletes any clone an earlier read left behind, for example after a crash. Reads take turns, so one never deletes another's clone.
- Firefox is read at most every 10 seconds. A clock set back does not stretch that wait.
- Nothing is stored and nothing is sent. Rows use app icons, never a site's icon. The detail pane shows the link as text, not a preview.

## Layout

| Path | Holds |
|---|---|
| `Parsing/` | the three parsers, pure functions over bytes, and a small SQLite wrapper |
| `Files/` | the file service: protocol and key, the live and isolated services, folder logic, fixture writers |
| `Library/` | link kinds, row building, the loader actor and the library that watches settings, files and access |
| `BookmarkList.swift` | the page and the root search catalog |
| `BookmarkActions.swift` | actions from a row, its loaded bookmark or its payload |
| `Strings.swift` | every string a person reads |

## Links that are not web links

Only `http` and `https` links open without a question. A `file:` link shows in Finder first and opens after a question. A link to another app, such as `mailto:` or an app's own scheme, opens after a question. Bookmarklets, `data:` links and a browser's own pages are never opened: they can be copied. Tabs and line breaks are removed before a link is judged, as browsers do, so `java\nscript:` counts as a script.

## Tests

`scripts/swiftpm.sh Packages/Features/Bookmarks test`. The benchmarks at 50,000 bookmarks run with `BOOKMARKS_BENCHMARK=1`, best in a release build with `-c release -Xswiftc -enable-testing`.
