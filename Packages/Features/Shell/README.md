# Shell Commands

Type `>` and a command in root search, as in Alfred, and press Return. The command runs in your login shell and its output streams into a page. Feature ID `shell`. The module is `ShellCommands`, so it cannot clash with a module or a type named Shell.

## What it declares

| Kind | What |
|---|---|
| Async provider `shell` | Takes over a root query that starts with `>`. One row: the command in full as typed, `memory: .never`. Nothing runs until Return. With no command after the prefix, the row is a hint that runs nothing, so Return never opens a web search for `>` |
| Command `run` | Run Shell Command. A required `command` argument, so the host asks for it in the search field |
| Command `history` | Shell History: commands going on now, then past commands by day |
| Command `open-in-terminal` | Hidden. Open Command in Terminal, for the actions that hand a command to Terminal |
| Settings pane | the shell, the working folder with Choose Working Folder…, the output limit, Keep history, Clear History |
| Permission | Accessibility, to paste output into the app you were using |

Every command sets `allowsDeepLinks` to false, and none is a fallback. The feature is on by default, as Alfred's `>` is.

## The prefix

The prefix is `>` and one optional space. The rest is the command, as typed. A command with a further space before it, such as `>  export TOKEN=…`, runs but is never saved, as in a shell with `HIST_IGNORE_SPACE`.

A command is refused, and its row says why, when it holds a line break or another control character, a character that changes the order text is drawn in, or starts with a hyphen or a plus sign, which zsh and bash read as options, or is longer than 32 KB. Each would run differently from how it shows. A tab is allowed.

A command is refused too when it could hide part of itself. The row is cut at its end and the one-line field shows the end after a paste, so padding in the middle could hide a second command from both. So a command may not hold a character that draws as a blank or as nothing, such as a no-break space, a zero width space, a Hangul filler or the blank Braille pattern, and may not hold more than three spaces or tabs in a row between its words. A zero width joiner or a variation selector right after an emoji is allowed, so emoji draw as they should. Runs of spaces before or after the command hide nothing and stay.

## Running

Return on the `>` row hands the text to `run` with a token only this feature instance knows. So every run goes through the host's pipeline: a link never starts one, and the host can refuse it in a panel session a link opened. `run` acts at once only for a launch from root, a page, a hotkey, or its own hand-off. Another feature's hand-off, a fallback, Tab and the rest put the text back in root search behind the prefix, where the user reads it and presses Return.

The shell starts as a login shell: `<shell> -l -c <command>`, with the command as one argument. csh and tcsh take `-l` only as their one flag, so they start as `<shell> -c <command>` and read `.cshrc` or `.tcshrc` as they do for every run. It reads your profile, such as `.zprofile`, so `PATH` is your own; it does not read `.zshrc`. On top of Kit's clean environment, which holds `PATH`, `HOME`, `LANG` and `TMPDIR`, a command gets `USER`, `LOGNAME` and `SHELL` from the account record, and `SSH_AUTH_SOCK` from the app's own environment when it is set there, so `git` over SSH reaches the agent. Nothing else is added, and `TERM` stays unset. Standard input reads from `/dev/null`. The working folder comes from settings, the home folder by default. There is no time limit.

Standard output and standard error go into one buffer in the order they arrive, with ANSI colors kept. The page keeps the newest output up to the limit in settings, 2 MB by default. Past it, the oldest output is dropped down to three quarters of the limit, cut after a line break, and the metadata says the start was dropped. The metadata shows the command, the shell, the folder, the start, the status, the run time once it ended, and last a note that the command gets no input, with Open in Terminal for one that needs it.

A page pulls its updates. Each time the host asks the page's stream for the next one, it gets everything since its last, as one update: the text appended since, the whole detail again after the start was dropped, or new metadata. So a command that prints without end never piles updates up behind a page, and nothing waits in memory but the kept output.

Copy Output and Paste Output leave out every escape sequence by the host's own rules, so they never hold text the page hides, such as a DCS string.

Turning the feature off stops every run. A run still looking up its shell and folder then never starts its process.

A run belongs to the feature, not to its page. Closing the panel, leaving the page, or the host's return to root search 90 seconds later leave it running. When it ends and no page shows it in the open panel, a toast says how in a few words, which the host shows as a HUD while the panel is closed. The toast has Show Output. A run the user stopped is not reported.

## Actions

| Where | Action | ID | Shortcut |
|---|---|---|---|
| `>` row | Run in Shell | `run-in-shell` | Return |
| `>` row | Copy Command | `copy-command` | Shift-Command-C |
| `>` row | Open in Terminal | `open-in-terminal` | Command-Return |
| Page with output | Copy Output, without colors | `copy-output` | Return, Shift-Command-C |
| Page with output | Paste Output, without colors | `paste-output` | |
| Page, running | Stop | `stop` | Control-C |
| Page, ended | Run Again, with the settings as they are now | `run-again` | Command-R |
| Page | Copy Command, Open in Terminal | `copy-command`, `open-in-terminal` | |
| History, past | Use Again: puts `> command` in root search, so a second Return runs it | `use-again` | Return |
| History, past | Show Output, while one of the last three runs | `show-output` | |
| History, past | Copy Command, Delete from History, Clear History after a question | `copy-command`, `delete`, `clear-history` | Shift-Command-C, Control-X, Control-Shift-X |
| History, running | Show Output, Stop, Copy Command | `show-output`, `stop`, `copy-command` | Return, Control-C |

A page without output puts Copy Command first, so Return on it never stops or runs anything. On the `>` row Copy Command comes second, so when the user turned Run Shell Command off and the host hides it, Return copies and never opens Terminal. A history row never runs at once.

Stop stops reading. Kit's process service then sends SIGTERM to the shell's whole process group, and SIGKILL to the group once the shell has exited or two seconds have passed. So Stop on a page or in Shell History ends `a | b` and `a && b` whole, and a child the command left in the background too. The page says Stopped at once, whatever the process does.

Open in Terminal writes a script to `Terminal/run-<uuid>.command` in the feature's cache folder. The folder and the file are mode 0700; the file is made new with `O_EXCL | O_NOFOLLOW`, and a link in place of the folder is refused. The script is the shell from settings as a login shell on its first line, then `/bin/rm -f --` on the script itself, so the command is on disk only until Terminal starts it, then `cd` to the working folder in single quotes, then the command. The workspace opens it with Terminal. A script Terminal never started is deleted when the next one is written, once it is ten minutes old.

## History

`history.json` in the feature's data folder, version 1, at most 200 entries, newest first. Each has the command, the start, the run time, the exit status and whether it was stopped. The same command run again moves to the top. Nothing is saved while Keep history is off; turning it off keeps what is saved. A file from a newer version is shown but never saved over, and settings says so. A damaged file is moved aside as `history-damaged-<n>.json`, and Clear History deletes those copies too. Hand-edited entries are cleaned when read: a command the feature would refuse is dropped. The feature's folder is left out of Time Machine and other backups, as Clipboard's is, because a command can hold a secret.

## Privacy

The command text and the output are never logged. The `>` row is never remembered or learned by root search. The feature reads nothing at activation but its own history file. A command runs with your rights; one that reads a protected folder, such as Desktop, can make macOS ask whether the launcher may read it, because the launcher started it. For the same reason a command has every permission you gave the launcher, such as Accessibility, Full Disk Access, Contacts and Automation of System Events, and macOS asks in the launcher's name for anything more. A command that needs the camera, the microphone or Bluetooth may be refused, because the launcher declares none of them. The settings footer says so and points to Open in Terminal.

## Services

| Key | Live | Isolated |
|---|---|---|
| `ShellProcessesKey` | Kit's process service from the context | `SimulatedShellProcesses`: starts nothing, echoes `echo`, otherwise says the run is simulated |
| `ShellSystemKey` | `LiveShellSystem`: the login shell from `getpwuid_r`, checked against `/etc/shells` and the file system; whether a folder or a program is there | `SimulatedShellSystem`: zsh, and every folder and program is there |

## Where to look

| File | Holds |
|---|---|
| `ShellFeature.swift` | the feature: manifest, commands, provider, pane, activation, the two command handlers |
| `Command/` | the prefix, the command checks, and the launch rules with the hand-off token |
| `Root/ShellProvider.swift` | the `>` row and its actions |
| `Running/` | the run, the board of runs, the page, the output buffer, the metadata, the setup from settings |
| `Terminal/TerminalScript.swift` | the script for Terminal |
| `History/` | the history file and its page |
| `Services/` | the two service keys |
| `Strings.swift` | every string a person reads |
