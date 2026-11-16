# Snippets

Saved text with dynamic placeholders. Paste a snippet from Search Snippets or root search, or type its keyword in any app to expand it. Read it next to `docs/FEATURES.md`.

## What it declares

| Kind | What |
|---|---|
| Command `search` | Search Snippets: a list with Pinned, loose and per-collection sections, a collection filter and a detail pane |
| Command `create` | Create Snippet: the editor form. Takes optional `text` and `name` arguments from code |
| Command `edit` | Edit Snippet for the snippet whose ID is in the `snippet` argument. Hidden from root search |
| Command `fill` | Asks for a snippet's arguments, then pastes. Hidden; a typed keyword opens it. Launched any other way, it shows the form before it pastes |
| Command `import` | Import Snippets: Raycast's JSON, this feature's export or data file, and Alfred's `.alfredsnippets` collections, through the file dialog service. Shows a page of what is added, added without its keyword, skipped as a duplicate or not valid, and saves only when the user confirms. Never from a link |
| Command `export` | Export Snippets: a JSON list in Raycast's shape, keywords as typed with the prefix. Never from a link |
| Commands `turn-on-expansion`, `turn-off-expansion` | switch keyword expansion |
| Catalog source and instant provider `snippet` | every snippet by name, and the snippet whose keyword is the whole query |
| Universal action `save-as-snippet` | selected text into the editor |
| Settings pane | expansion switch, trigger, keyword prefix, inside words, excluded apps, root search, order, files |

## Where to look

| File | Shows |
|---|---|
| `SnippetsFeature.swift` | the feature: activation, commands, settings, import and export |
| `SnippetLibrary.swift` | one JSON file through `JSONFileStore`, loads and changes in order, reload on file change, read-only while the file is damaged |
| `LibraryIndex.swift` | every lookup, built off the main thread once per change |
| `TextExpansion.swift` | `TextExpansionService` start, keyword updates and the handler, all off the main thread. Text with a line break goes to Fill In Snippet, which pastes it |
| `SnippetSource.swift`, `SnippetRows.swift` | the list, root search rows, the instant answer and the detail pane |
| `SnippetActions.swift`, `SnippetForms.swift`, `SnippetValidation.swift` | actions, forms and what validation says |
| `SnippetRenderer.swift` | placeholders through `KitTemplates` |
| `SnippetTransfer.swift` | the import and export format, and the rules that decide each imported entry |
| `SnippetImportFile.swift` | reading a picked file: JSON, or an Alfred collection, told apart by its bytes |
| `ZipArchive.swift` | a ZIP reader over the central directory and the Compression framework, with its limits |
| `PlaceholderMapping.swift` | Alfred's placeholders in Kit's grammar, and the ones that work differently here |
| `SnippetImportPage.swift` | the page that shows an import before it is saved |
| `Strings.swift` | every string a user reads |

## Rules this feature follows

- Expansion is off until the user turns it on. The feature never asks for a permission itself; the host's grant flow does, from an action or the settings pane.
- No file work on the main thread. The store is an actor, and rows, details, the index and keyword registration are built in `@concurrent` functions.
- A file that cannot be read is never overwritten. The feature reports it and saves nothing until the file is fixed or removed. A file from a newer version is used but never saved over.
- A permission is followed only while expansion is on and waits for it, because the live permission stream polls.
- Import applies the editor's keyword rules. A keyword the editor would refuse, or one another snippet has with different text, is left out and the snippet is still imported. An entry with the same keyword and text as a snippet the user has is skipped.
- An imported file is hostile until read. Names become one line, text loses control characters other than tab and line breaks, and an archive is read in memory within fixed limits: plain files at the top level only, stored or deflate, at most 5,000 entries, 1 MB each and 50 MB in all, each checked against its declared size and checksum. Nothing from an archive is written to disk.
- An expansion that holds a line break is pasted, never typed, wherever the break came from, so a terminal never runs a line by itself.
