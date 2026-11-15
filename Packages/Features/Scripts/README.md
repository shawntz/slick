# Script Commands

A script dropped in a script folder becomes a command. Feature ID `scripts`.

## The script format

Metadata lives in comments at the top of the script. The format is the one the public script command collections use, documented at <https://github.com/raycast/script-commands> in `README.md`, `documentation/ARGUMENTS.md` and `documentation/OUTPUTMODES.md`. Scripts written for those collections work unchanged. The same keys are read under this project's own prefix, `@` plus the URL scheme in `Kit.Brand` plus `.`.

```bash
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Say Hello
# @raycast.mode compact
# @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }
echo "Hello ${1:-World}"
```

| Key | Required | Notes |
|---|---|---|
| `schemaVersion` | yes | must be `1` |
| `title` | yes | the command's title |
| `mode` | yes | `fullOutput`, `compact`, `silent`, `inline`, or this feature's `list` |
| `packageName` | | the subtitle; the folder's name when missing |
| `icon`, `iconDark` | | an emoji, an image path relative to the script, or an `https` URL |
| `currentDirectoryPath` | | relative to the script's folder, absolute, or `~/` |
| `needsConfirmation` | | `true` asks before running |
| `refreshTime` | inline | `10s`, `5m`, `12h`, `1d`; at least ten seconds |
| `argument1` to `argument3` | | JSON with `type`, `placeholder`, `optional`, `percentEncoded` and `data`; the type is `text`, `password` or `dropdown` |
| `description`, `author`, `authorURL`, `platform` | | `platform` must include `macos` |
| `filterAction` | | own prefix only, list scripts only: `auto`, `open`, `copy`, `paste` |

Comment markers are `#`, `//` and `--`. The parse is strict. A missing required key, an unknown mode, broken argument JSON or an unusable inline refresh time is an error, and the script is not a command. Unknown or repeated keys are warnings. Manage Script Commands shows both, with line numbers, and the settings pane shows a count.

## Running

A script runs through the interpreter its first line names, `#!/usr/bin/env python3` for example, so it needs no executable bit. Files with no first line run by extension: `.sh`, `.bash`, `.zsh` and `.applescript`. The working directory is the script's folder unless `currentDirectoryPath` says otherwise.

The environment is Kit's clean one, `HOME`, `LANG` and `TMPDIR`, with `PATH` from settings. By default `PATH` lists Homebrew's folders, then the system's. List scripts also get the session variables they returned. Nothing else from the user's shell reaches a script.

| Mode | What the user sees |
|---|---|
| `silent` | the panel closes at once; the last line shows as a HUD |
| `compact` | the last line shows as a toast |
| `fullOutput` | a page streams standard output and standard error as they arrive, ANSI colors kept |
| `inline` | the first line is the command's subtitle, refreshed on `refreshTime` only after the user turns that on |
| `list` | the script prints Script Filter JSON for each query and the rows show in a list |

A script that fails shows the last line of its error output, with a Show Output button for all of it. The time limit and the output limit in settings stop a script that runs too long or prints too much. Leaving a full output or list page stops its script.

## List scripts

List scripts print JSON in the Script Filter format documented at <https://www.alfredapp.com/help/workflows/inputs/script-filter/json/>. The query arrives as `$1`, the script runs again 120 ms after typing stops, and again after `rerun` seconds. Read: `items` with `uid`, `title`, `subtitle`, `arg`, `icon`, `valid`, `autocomplete`, `type`, `mods`, `text.copy`, `quicklookurl` and `variables`, and top-level `rerun` and `variables`. Top-level variables come back as environment variables on the next run, except names that could change how programs load or find commands. Output is not trusted: depth, item count and text length are capped, and wrong types are ignored.

Return acts on the row's `arg` by `filterAction`. `auto` opens `http` and `https` links and paths, and copies anything else. Return with modifiers acts on that modifier's `arg`.

## Safety

A script is the user's own code and runs with their rights. The settings pane says so. Scripts in a folder the user adds are listed but stay off until the user turns the folder on. Nothing runs that the user did not start, except inline scripts the user turned automatic refresh on for.

A script with `needsConfirmation` asks before every run and never refreshes by itself, whatever the settings hold. A `needsConfirmation` value other than `true` or `false` asks too, with a warning. A list script's variables never set names that make a shell or an interpreter load other code, such as `BASH_ENV`, `ENV`, `ZDOTDIR`, `NODE_OPTIONS` or `PYTHONPATH`. Zero characters never reach a process.

## Where to look

| File | Holds |
|---|---|
| `ScriptsFeature.swift` | the feature: folders, watching, scanning, commands, settings, status |
| `Metadata/HeaderParser.swift` | the header parse and its problems |
| `Metadata/Interpreter.swift` | the interpreter from the first line, icons, paths |
| `Library/` | the `ScriptLibrary` service: the file system, and an in-memory one for isolated runs |
| `Catalog/` | scripts found in a scan, command IDs, process requests |
| `Running/` | the output modes, the full output page, captured output with limits |
| `List/` | Script Filter JSON and the list page |
| `Manage/` | Manage Script Commands |
| `Create/` | Create Script Command and its templates |
| `Strings.swift` | every string a user reads |
