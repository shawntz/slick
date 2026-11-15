# Quicklinks

Open a site, a search or a deep link by typing its name, and search the web when nothing else matches. About thirty web searches are built in.

## What it declares

| Kind | What |
|---|---|
| Catalog source `quicklink` | one row per quicklink without arguments, `quicklink:<id>` |
| Command `open.<id>` | one per quicklink with arguments, with fields in the search bar; those that take the typed text can be fallbacks, the default search engine first |
| Instant provider `web-address` | a typed address such as `example.com` offers to open it |
| Commands `search`, `create`, `edit`, `import`, `export` | Search Quicklinks, Create Quicklink, Edit Quicklink, Import Quicklinks, Export Quicklinks |
| Universal actions | Search the Web and Search With for selected text, Open Link and Save as Quicklink for a selected link |
| Settings pane | the default search engine, fallbacks on or off, address detection on or off, Restore Default Searches, Show Quicklinks File in Finder |

## Where to look

| File | Shows |
|---|---|
| `QuicklinksFeature.swift` | the feature: the file, the watch, declarations, opening, changes |
| `LinkTemplate.swift` | Kit templates with `{query}` as a short form, and values encoded for the part of the link they land in |
| `AddressDetector.swift`, `TopLevelDomains.swift` | the strict address check, one pass over bytes for ordinary words |
| `QuicklinkRows.swift` | rows, the catalog, the list pages and the commands |
| `QuicklinkActions.swift` | every action, built from an ID and looked up again when it runs |
| `QuicklinkForms.swift` | the editor, its rules, and the form for argument values |
| `QuicklinkExchange.swift` | import and export as JSON |
| `DefaultSearches.swift` | the built-in searches |
| `Strings.swift` | every string a user reads |

## Rules this feature follows

- The file is JSON through `JSONFileStore`, written atomically. A file that cannot be read blocks saving until it is fixed or deleted, so a hand edit in progress is never overwritten.
- No network request at all. Icons are Kit's favicon icons, which the host resolves from its cache.
- Every link opens through Kit's workspace service. A value can never change the scheme the link was written with, and a link that starts with a value must be a web link.
- The address detector runs on the main thread inside the keystroke: no I/O, no locks, nil on the first byte for text that starts with anything but a letter or a digit, and nil after one pass for words.
- Parsing links, cleaning a file read from disk, building rows and merging an import run off the main thread, so a file of fifty thousand quicklinks does not stall the panel.
