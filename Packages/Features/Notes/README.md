# Notes

Quick notes kept as plain Markdown files that any editor can open. Write one from a form or straight from root search, find it by its title or its text, and edit, copy, paste, pin, rename, duplicate or trash it from the launcher. The module is `MarkdownNotes`, because the SDK has private frameworks whose names start with `Notes`. Read it next to `docs/FEATURES.md`.

## What it declares

| Kind | What |
|---|---|
| Command `search` | Search Notes: a list with Pinned, then a section per day, a Markdown detail pane, and search over titles and text |
| Command `create` | Create Note: title, text and tags. Takes an undeclared `text` argument from code |
| Command `append` | Append to Note: an optional `text` argument, then a list to pick the note |
| Instant provider `notes.capture` | `note`, a space and text: Create Note at the top of root search; Return saves it |
| Catalog source `notes` | note titles in root search, behind a setting that starts off |
| Settings pane | root search switch, the notes folder, the quick capture switch |

## Where things live

- A note is one `.md` file in the notes folder, by default `Notes` in the feature's data folder. `.markdown` files are read too. Only the folder itself is read, not folders inside it.
- The title is the first line with text, or that line's heading text. The file is named after it: slashes and colons become dashes, control and direction characters go, dots leave the ends, and a number follows when the name is taken.
- Tags are the note's last line when it holds only `#tag` words. Bear, Obsidian and iA Writer read such a line as tags; every other editor shows it as text.
- Pins live in `pins.json` in the feature's data folder, by folder and file name. A pin never touches the note, so the file, its date and its place in the list stay the same.

## Where to look

| File | Shows |
|---|---|
| `NotesFeature.swift` | commands, settings, status, the folder buttons and notices |
| `Library/NoteLibrary.swift` | the main thread's view: index, pins, watch, changes, guarded folders |
| `Library/NoteStore.swift` | the actor that scans and writes, with the caps |
| `Disk/PosixNoteDisk.swift` | every file call: no links, no pipes, atomic exclusive writes |
| `Disk/GuardedPlace.swift` | which folders macOS guards with a prompt |
| `Text/NoteText.swift` | title, body, tags, composing, renaming and appending in place |
| `Text/NoteSearch.swift`, `Pages/NoteRows.swift` | search, highlights, snippets and sections |
| `Pages/` | the list, detail, forms, actions and the Append to Note picker |
| `Root/` | quick capture and the catalog |
| `Strings.swift` | every string a user reads |

## Rules this feature follows

- Activation reads only the notes folder and starts its watch. It asks for nothing and opens no permission stream.
- Choose Folder asks for folders only. A folder that macOS guards, such as one in Documents, is read for the first time right after the user chooses it in settings, which is when macOS may ask. A later launch reads it only if that read worked; otherwise the list waits for Read Folder.
- Every read and write runs in an actor or a `@concurrent` function. A scan reads only files whose size, inode or date changed.
- Writes go to a hidden file beside the note and are renamed into place. A save from the editor that finds the file changed since it opened writes a new note beside it instead.
- Edit, Rename and Append change only a note whose bytes are exactly its text in UTF-8, after an optional byte order mark, which they keep. A note in Latin-1 or UTF-16 is listed, searched, copied and duplicated, and opens in the editor, but the launcher never writes over it.
- Switching to a folder and reading it is one step in the store, and a rescan reads only the folder it was meant for, so a read never lands on a guarded folder that waits for the user.
- Quick capture skips at most 1,024 blanks after `note `.
- Caps: 5,000 notes, 1 MB of each note for search, 64 MB of text held for search, 50,000 folder entries per scan. Past a cap the list says so in its notice and keeps working.
- Symbolic links, pipes, devices and folders named like notes are never opened. A file that is not text is left out. A file only in iCloud is listed by its name and never read by a scan.
- Outside the live app the disk service touches only the run's own temporary folders.
- Moving to the Trash and opening in an editor go through the workspace service, after a check on disk that the note is still a regular file in the folder.
