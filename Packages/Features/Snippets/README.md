# Snippets

Saved text with dynamic placeholders. Paste a snippet from Search Snippets or root search, or type its keyword in any app to expand it. Read it next to `docs/FEATURES.md`.

## What it declares

| Kind | What |
|---|---|
| Command `search` | Search Snippets: a list with Pinned, loose and per-collection sections, a collection filter and a detail pane |
| Command `create` | Create Snippet: the editor form. Takes optional `text` and `name` arguments from code |
| Command `edit` | Edit Snippet for the snippet whose ID is in the `snippet` argument. Hidden from root search |
| Command `fill` | Asks for a snippet's arguments, then pastes. Hidden; a typed keyword opens it. Launched any other way, it shows the form before it pastes |
| Commands `import`, `export` | JSON through the file dialog service |
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
| `TextExpansion.swift` | `TextExpansionService` start, keyword updates and the handler, all off the main thread |
| `SnippetSource.swift`, `SnippetRows.swift` | the list, root search rows, the instant answer and the detail pane |
| `SnippetActions.swift`, `SnippetForms.swift`, `SnippetValidation.swift` | actions, forms and what validation says |
| `SnippetRenderer.swift` | placeholders through `KitTemplates` |
| `SnippetTransfer.swift` | the import and export format and the merge rules |
| `Strings.swift` | every string a user reads |

## Rules this feature follows

- Expansion is off until the user turns it on. The feature never asks for a permission itself; the host's grant flow does, from an action or the settings pane.
- No file work on the main thread. The store is an actor, and rows, details, the index and keyword registration are built in `@concurrent` functions.
- A file that cannot be read is never overwritten. The feature reports it and saves nothing until the file is fixed or removed. A file from a newer version is used but never saved over.
- A permission is followed only while expansion is on and waits for it, because the live permission stream polls.
- Import applies the editor's keyword rules. A keyword the editor would refuse is left out and the snippet is still imported.
