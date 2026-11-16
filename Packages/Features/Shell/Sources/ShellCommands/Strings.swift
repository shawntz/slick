import Foundation
import Kit

/// Every string the user reads. Titles in title case, everything else a plain sentence. The product
/// name is passed in from `Kit.Brand`, never written here.
nonisolated enum Strings {
    static let featureName = "Shell Commands"
    static let summary = "Runs a command you type after > in your login shell and shows its output."
    static let accessibilityReason = "Paste a command's output into the app you were using."

    static let runCommand = "Run Shell Command"
    /// No "terminal": that query belongs to the Terminal app.
    static let runKeywords = ["shell", "command", "zsh", "bash"]
    static let commandPlaceholder = "Command"
    static let historyCommand = "Shell History"
    static let historyKeywords = ["shell", "commands"]
    static let terminalCommand = "Open Command in Terminal"

    /// What the simulated shell prints in scenarios, where no process starts.
    static let simulatedOutput = "This is a simulated run. No process started."

    /// A run time: tenths of a second under a minute, then minutes and seconds, then hours and
    /// minutes.
    static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        if value < 60 {
            return value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s"
        }
        let whole = Int(min(value, Double(Int32.max)))
        if whole < 3600 { return "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3600) h \(whole % 3600 / 60) min"
    }

    enum Root {
        static let section = "Shell"
        static let runs = "Press Return to run it in your shell."
        static let runsHidden = "Press Return to run it in your shell. It is not saved to history."
        static let unnamed = "Command"
        static let hintTitle = "Run a Shell Command"
        static let hint = "Type a command after > and press Return to run it in your shell."

        static func problem(_ problem: ShellCommand.Problem) -> String {
            Failures.message(problem)
        }
    }

    enum Actions {
        static let runInShell = "Run in Shell"
        static let openInTerminal = "Open in Terminal"
        static let copyCommand = "Copy Command"
        static let copiedCommand = "Copied Command"
        static let copyOutput = "Copy Output"
        static let copiedOutput = "Copied Output"
        static let pasteOutput = "Paste Output"
        static let noOutput = "No Output Yet"
        static let stop = "Stop"
        static let stopping = "Stopped Command"
        static let runAgain = "Run Again"
        static let showOutput = "Show Output"
        static let useAgain = "Use Again"
        static let delete = "Delete from History"
        static let deleted = "Deleted from History"
        static let clearHistory = "Clear History"
        static let clearQuestion = "Clear Shell History?"
        static let clearMessage =
            "Every saved command is deleted, and so are damaged history files set aside earlier. This cannot be undone."
        static let clearConfirm = "Clear History"
        static let cleared = "Cleared Shell History"
    }

    enum Page {
        /// A page's title: the command on one line, cut to 60 characters.
        static func title(_ command: String) -> String {
            let line = DisplayText.oneLine(command)
            return line.count <= 60 ? line : String(line.prefix(59)) + "…"
        }

        static let commandLabel = "Command"
        static let shellLabel = "Shell"
        static let folderLabel = "Folder"
        static let startedLabel = "Started"
        static let statusLabel = "Status"
        static let runTimeLabel = "Run time"
        static let outputLabel = "Output"
        static let inputLabel = "Input"

        static let statusRunning = "Running"
        static func statusExited(_ code: Int32) -> String { "Exited with status \(code)" }
        static let statusStopped = "Stopped"
        static func statusCouldNotStart(_ reason: String) -> String { "Could not start: \(reason)" }

        static func outputDropped(_ limit: OutputLimit) -> String {
            "The start was dropped. This page keeps the last \(Settings.outputLimitOption(limit))."
        }

        static let inputNote =
            "None. Standard input is closed, so a command that asks for input gets none here. "
            + "Use Open in Terminal for such a command."
    }

    /// What the user hears when a run ends while no page shows it: a HUD while the panel is closed.
    enum Reports {
        static let finished = "Shell Command Finished"
        static func exited(_ code: Int32) -> String { "Shell Command Exited with Status \(code)" }
        static let couldNotStart = "Shell Command Could Not Start"
    }

    enum Failures {
        static func title(_ problem: ShellCommand.Problem) -> String {
            switch problem {
            case .empty: "No Command"
            case .tooLong: "Command Too Long"
            case .lineBreak: "Command Has a Line Break"
            case .directionControl: "Command Has Hidden Characters"
            case .invisibleCharacter: "Command Has an Invisible Character"
            case .longSpace: "Command Has a Long Run of Spaces"
            case .startsWithHyphen: "Command Starts with a Hyphen"
            case .startsWithPlus: "Command Starts with a Plus Sign"
            }
        }

        static func message(_ problem: ShellCommand.Problem) -> String {
            switch problem {
            case .empty:
                "Type a command after >."
            case .tooLong:
                "A command can have at most 32 KB. Put a longer one in a script and run the script."
            case .lineBreak:
                "It holds a line break or another control character, so it would not run as it shows. "
                    + "Put it in a script and run the script."
            case .directionControl:
                "It holds characters that change the order text is drawn in, so it would not run as it shows."
            case .invisibleCharacter:
                "It holds a character that draws as a blank or as nothing, so it would not run as it shows. "
                    + "Type the command again with plain spaces."
            case .longSpace:
                "More than three spaces in a row can push part of a command out of sight. "
                    + "Shorten each run of spaces to three or fewer."
            case .startsWithHyphen, .startsWithPlus:
                "A shell would read it as an option."
            }
        }

        static let cannotRun = "This Command Cannot Run"
        static let linkRefused = "Links Cannot Run Shell Commands"
        static let linkRefusedMessage = "Type the command after > in the search field instead."
        static let shellNotFound = "Shell Not Found"
        static func shellNotFoundMessage(_ path: String) -> String {
            "\(DisplayText.oneLine(path)) cannot run on this Mac. Choose another shell in settings."
        }
        static let folderNotFound = "Working Folder Not Found"
        static func folderNotFoundMessage(_ folder: String) -> String {
            "\(folder) is not a folder. Choose another one in settings, or leave it empty for your home folder."
        }
        static let folderNotUsable = "Working Folder Not Usable"
        static let folderNotUsableMessage =
            "Enter a folder that starts with / or ~, or leave it empty for your home folder."
        static let terminalFailed = "Could Not Open in Terminal"
        static let terminalShellPath =
            "The shell's path is not absolute or holds a space, so a script cannot name it on its first line."
        static let terminalFolderNotAFolder = "The folder for Terminal scripts is not a folder."
    }

    enum History {
        static let placeholder = "Search shell history"
        static let runningSection = "Running"
        static let emptyTitle = "No Shell History"
        static let emptyMessage = "Commands you run after > show here."
        static let offTitle = "Shell History Is Off"
        static let offMessage = "Turn on Keep history in the Shell Commands settings to save the commands you run."
        static let runningTag = "Running"
        static func exitTag(_ code: Int32) -> String { "Exit \(code)" }
        static let stoppedTag = "Stopped"
        static let notStartedTag = "Not Started"
    }

    enum Status {
        static let readOnlyTitle = "Shell History Is Read Only"
        static let readOnlyMessage =
            "The history file comes from a newer version. New commands show until you quit, and the file is "
            + "left as it is."
    }

    enum Settings {
        static let runSection = "Running Commands"
        static let runFooter =
            "A command runs with your rights, as if you typed it in Terminal, in a login shell that reads your "
            + "profile, such as .zprofile, but not .zshrc. On top of a clean environment it gets USER, LOGNAME "
            + "and SHELL from your account, and SSH_AUTH_SOCK when the launcher has one, so git over SSH works. "
            + "Nothing else is added. Standard input is closed. Stop ends the command and every process it "
            + "started. Links can never run a command here. A command that reads a protected folder, such as "
            + "Desktop, can make macOS ask whether the launcher may read it. A command has every permission you "
            + "gave the launcher, such as Accessibility and Full Disk Access, because macOS counts it as the "
            + "launcher's. A command that needs the camera, the microphone or Bluetooth may be refused here. "
            + "Run such a command with Open in Terminal."
        static let shell = "Shell"
        static let shellInfo = "Your login shell is the one Terminal uses."
        static func shellOption(_ choice: ShellChoice) -> String {
            switch choice {
            case .login: "Login Shell"
            case .zsh: "zsh"
            case .bash: "bash"
            case .sh: "sh"
            }
        }
        static let workingFolder = "Working folder"
        static let workingFolderPlaceholder = "~"
        static let workingFolderInfo = "Commands start in this folder. Leave it empty for your home folder."
        static let chooseFolder = "Choose Working Folder…"
        static let chooseFolderTitle = "Choose Working Folder"
        static let folderChosen = "Working Folder Chosen"
        static let notAFolder = "Choose a Folder"
        static let notAFolderMessage = "The working folder must be a folder, not a file."
        static let outputLimit = "Keep output up to"
        static let outputLimitInfo =
            "A page keeps the newest output up to this size and says when it dropped the start."
        static func outputLimitOption(_ limit: OutputLimit) -> String {
            switch limit {
            case .halfMegabyte: "512 KB"
            case .oneMegabyte: "1 MB"
            case .twoMegabytes: "2 MB"
            case .eightMegabytes: "8 MB"
            case .thirtyTwoMegabytes: "32 MB"
            }
        }

        static let historySection = "History"
        static func historyFooter(appName: String) -> String {
            "Commands are kept in Features/shell/\(ShellHistory.fileName) in \(appName)'s data folder, at most "
                + "\(ShellHistory.limit). A command you type with a space before it is never saved, as in a shell. "
                + "The folder is left out of backups."
        }
        static let keepsHistory = "Keep history"
        static let keepsHistoryInfo = "Turning this off keeps what is saved until you clear it."
    }
}
