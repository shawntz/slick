import Foundation
import Kit

/// Every string a user reads, in one place so it can be translated later. Command and action
/// titles use title case; everything else is a plain sentence.
nonisolated enum Strings {
    // MARK: - Feature

    static let featureName = "Script Commands"
    static let featureSummary = "Turn the scripts in your script folders into commands."
    static let pasteReason = "Paste a list script's result into the frontmost app."

    // MARK: - Commands

    static let createTitle = "Create Script Command"
    static let openFolderTitle = "Open Script Folder"
    static let reloadTitle = "Reload Scripts"
    static let manageTitle = "Manage Script Commands"
    static let createKeywords = ["new script", "template"]
    static let manageKeywords = ["scripts", "problems"]

    static func reloaded(commands: Int, problems: Int) -> String {
        let found = commands == 1 ? "Found 1 script command" : "Found \(commands) script commands"
        switch problems {
        case 0: return found
        case 1: return found + ". 1 script has a problem"
        default: return found + ". \(problems) scripts have problems"
        }
    }

    static func runFallback(_ title: String, text: String) -> String {
        "\(title) with \"\(text)\""
    }

    static func confirmRun(_ title: String) -> String {
        "Run \(title)?"
    }

    static let confirmRunButton = "Run"

    // MARK: - Running

    static func finished(_ title: String) -> String {
        "\(title) finished"
    }

    static func failedWithCode(_ code: Int32) -> String {
        "The script ended with exit code \(code)."
    }

    static func failed(_ title: String) -> String {
        "\(title) failed"
    }

    static func timedOut(_ title: String, after limit: String) -> String {
        "\(title) was stopped after \(limit)"
    }

    static let timedOutMessage = "Raise the time limit in settings if the script needs longer."

    static func overLimit(_ title: String, limit: String) -> String {
        "\(title) printed more than \(limit) and was stopped"
    }

    static let overLimitMessage = "Raise the output limit in settings, or make the script print less."

    static func couldNotStart(_ title: String) -> String {
        "\(title) could not start"
    }

    static let showOutput = "Show Output"
    static let copyOutput = "Copy Output"
    static let runAgain = "Run Again"
    static let stopScript = "Stop Script"
    static let editWith = "Edit With"
    static let outputTitleSuffix = "Output"

    static func outputTitle(_ title: String) -> String {
        "\(title) \(outputTitleSuffix)"
    }

    // MARK: - Full output

    static let statusLabel = "Status"
    static let runTimeLabel = "Run time"
    static let exitCodeLabel = "Exit code"
    static let statusRunning = "Running"
    static let statusFinished = "Finished"
    static let statusStopped = "Stopped"
    static let statusTimedOut = "Stopped at the time limit"
    static let statusOverLimit = "Stopped at the output limit"

    static func statusExitCode(_ code: Int32) -> String {
        "Ended with exit code \(code)"
    }

    static func statusCouldNotStart(_ reason: String) -> String {
        "Could not start: \(reason)"
    }

    static func seconds(_ value: String) -> String {
        "\(value) s"
    }

    static func outputCut(limit: String) -> String {
        "\n\nThe output passed \(limit), so the script was stopped.\n"
    }

    // MARK: - Inline

    static let turnOnRefresh = "Turn On Automatic Refresh"
    static let turnOffRefresh = "Turn Off Automatic Refresh"
    static let refreshOn = "This script now refreshes by itself"
    static let refreshOff = "This script now runs only when you run it"

    // MARK: - List scripts

    static func searchPlaceholder(_ title: String) -> String {
        "Search \(title)"
    }

    static let complete = "Complete"
    static let copyArgument = "Copy"
    static let openArgument = "Open"
    static let pasteArgument = "Paste"
    static let noResults = "No Results"
    static let notJSON = "The script printed something other than Script Filter JSON."
    static let emptyOutput = "The script printed nothing."
    static let tooDeep = "The script's JSON is nested too deeply to read."
    static let noItems = "The script's JSON has no \"items\" list."

    static func listFailed(_ title: String) -> String {
        "\(title) failed"
    }

    static func skippedItems(_ count: Int) -> String {
        count == 1 ? "1 item had no title and was left out." : "\(count) items had no title and were left out."
    }

    static func truncatedItems(shown: Int, total: Int) -> String {
        "Showing the first \(shown) of \(total) items."
    }

    static func withModifiers(_ title: String, _ modifiers: KeyModifiers) -> String {
        "\(title) (\(modifiers.symbols))"
    }

    // MARK: - Manage Script Commands

    static let manageSearchPlaceholder = "Search script commands"
    static let noScriptsTitle = "No Script Commands"
    static let noScriptsMessage = "Create one, or put a script in the script folder."
    static let defaultFolderName = "Default Folder"
    /// The default script folder's name on disk.
    static let defaultFolderFileName = "Script Commands"
    static let runScript = "Run Script"
    static let turnOnFolder = "Turn On Folder"
    static let tagOff = "Off"
    static let tagProblem = "Problem"
    static let tagWarning = "Warning"

    static func turnOnFolderQuestion(_ folder: String) -> String {
        "Run scripts from \(folder)?"
    }

    static let turnOnFolderMessage =
        "Every script in this folder becomes a command you can run. Scripts run as you and can do anything you can do."

    static func folderTurnedOn(_ folder: String) -> String {
        "Scripts in \(folder) can run now"
    }

    static let detailFile = "File"
    static let detailFolder = "Folder"
    static let detailMode = "Mode"
    static let detailInterpreter = "Interpreter"
    static let detailCommandID = "Command ID"
    static let detailFolderOff = "This folder is off. Turn it on to run its scripts."
    static let detailProblems = "Problems"
    static let detailNoProblems = "No problems."

    static func problemLine(_ problem: ScriptProblem) -> String {
        let kind = problem.severity == .error ? "Error" : "Warning"
        guard let line = problem.line else { return "\(kind): \(problem.message)" }
        return "\(kind) on line \(line): \(problem.message)"
    }

    static func modeName(_ mode: ScriptMode) -> String {
        switch mode {
        case .fullOutput: "Full Output"
        case .compact: "Compact"
        case .silent: "Silent"
        case .inline: "Inline"
        case .list: "List"
        }
    }

    // MARK: - Status

    static func problemsStatus(_ count: Int) -> String {
        count == 1 ? "1 script has a problem" : "\(count) scripts have problems"
    }

    static let problemsStatusMessage = "Open Manage Script Commands to see what to fix."

    static func offStatus(_ count: Int) -> String {
        count == 1
            ? "1 script is off until you turn on its folder"
            : "\(count) scripts are off until you turn on their folders"
    }

    static let offStatusMessage = "Turn folders on below, under Folders allowed to run."

    static func missingFolderStatus(_ path: String) -> String {
        "The script folder \(path) was not found"
    }

    // MARK: - Create Script Command

    static let createSubmit = "Create Script"
    static let fieldTitle = "Title"
    static let fieldTitlePlaceholder = "Say Hello"
    static let fieldLanguage = "Language"
    static let fieldMode = "Mode"
    static let fieldPackage = "Package name"
    static let fieldPackageInfo = "Shown under the title. Leave it empty to show the folder's name."
    static let fieldFolder = "Folder"
    static let titleNeedsLetters = "Use at least one letter or digit."

    static func fileExists(_ name: String) -> String {
        "A file named \(name) already exists in this folder."
    }

    static func created(_ name: String) -> String {
        "Created \(name)"
    }

    static let templateGreeting = "Hello World!"
    static let templateYouTyped = "You typed:"
    static let templateOptionalHeading = "Optional parameters:"
    static let templateDocumentation = "Documentation: https://github.com/raycast/script-commands"

    // MARK: - Settings

    static let safetyNote =
        "Scripts are your own code. They run as you and can do anything you can do, so add only folders whose scripts you trust."
    static let foldersSection = "Folders"
    static let foldersTitle = "Script folders"
    static let foldersInfo =
        "Scripts directly inside these folders become commands. The default folder is always on."
    static let enabledFoldersTitle = "Folders allowed to run"
    static let enabledFoldersInfo =
        "Scripts in a newly added folder are listed but stay off until you turn the folder on here."
    static let runningSection = "Running"
    static let timeoutTitle = "Time limit"
    static let timeoutInfo = "A script still running after this long is stopped."
    static let outputLimitTitle = "Output limit"
    static let outputLimitInfo = "A script that prints more than this is stopped."
    static let searchPathTitle = "Command search path"
    static let searchPathInfo =
        "The PATH scripts run with. Scripts also get HOME, LANG and TMPDIR, and nothing else from your shell."
    static let inlineSection = "Inline Scripts"
    static let inlineTitle = "Refresh automatically"
    static let inlineInfo =
        "Only the inline scripts you check here run by themselves, on their refresh time. The others run when you run them."
    static let reloadButtonInfo = "Scripts are found again by themselves whenever a script folder changes."

    static func timeoutName(_ timeout: ScriptTimeout) -> String {
        switch timeout {
        case .tenSeconds: "10 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .never: "No limit"
        }
    }

    static func outputLimitName(_ limit: OutputLimit) -> String {
        switch limit {
        case .quarterMegabyte: "256 KB"
        case .oneMegabyte: "1 MB"
        case .fourMegabytes: "4 MB"
        case .sixteenMegabytes: "16 MB"
        }
    }

    // MARK: - Header problems

    enum Problem {
        static func missing(_ key: String, prefix: String) -> String {
            "Add a \(prefix)\(key) line."
        }

        static func unknownKey(_ key: String) -> String {
            "\(key) is not a key this format knows, so the line is ignored."
        }

        static func ownPrefixOnly(_ key: String, prefix: String) -> String {
            "\(key) is read only as \(prefix)\(key), so the line is ignored."
        }

        static func duplicate(_ key: String) -> String {
            "\(key) is set more than once. The first one is used."
        }

        static func malformed() -> String {
            "This metadata line has no key. Write it as @prefix.key value."
        }

        static func emptyValue(_ key: String) -> String {
            "\(key) has no value, so the line is ignored."
        }

        static func schemaVersion(_ value: String) -> String {
            "Schema version \(value) is not supported. Use 1."
        }

        static func mode(_ value: String) -> String {
            "\"\(value)\" is not a mode. Use fullOutput, compact, silent, inline or list."
        }

        static func confirmation(_ value: String) -> String {
            "needsConfirmation must be true or false, not \"\(value)\". The script asks before it runs until this is fixed."
        }

        static func refreshTime(_ value: String) -> String {
            "\"\(value)\" is not a refresh time. Use a whole number with s, m, h or d, such as 10s or 5m."
        }

        static func refreshTooShort(_ value: String) -> String {
            "The refresh time \(value) is shorter than 10 seconds, so 10 seconds is used."
        }

        static let refreshOnlyInline = "Only inline scripts refresh, so refreshTime is ignored."
        static let inlineWithoutRefresh = "An inline script needs a refreshTime. Until it has one, it runs as compact."

        static func platform(_ value: String) -> String {
            "This script is for \(value), not macOS."
        }

        static func filterAction(_ value: String) -> String {
            "\"\(value)\" is not a filter action. Use auto, open, copy or paste. auto is used."
        }

        static let filterActionOnlyList = "filterAction applies only to list scripts, so it is ignored."
        static let argumentsInList =
            "List scripts get the search text as their argument, so argument lines are ignored."

        static func icon(_ value: String) -> String {
            "\"\(value)\" is not an emoji, an image path or an https URL, so the default icon is used."
        }

        static func argumentGap(_ index: Int) -> String {
            "argument\(index) is set, but argument\(index - 1) is not."
        }

        static func argumentJSON(_ index: Int) -> String {
            "argument\(index) must be a JSON object, such as { \"type\": \"text\", \"placeholder\": \"name\" }."
        }

        static func argumentType(_ index: Int, _ value: String) -> String {
            "argument\(index) has the type \"\(value)\". Use text, password or dropdown."
        }

        static func argumentNoType(_ index: Int) -> String {
            "argument\(index) has no type, so text is used."
        }

        static func argumentPlaceholder(_ index: Int) -> String {
            "argument\(index) needs a placeholder."
        }

        static func argumentField(_ index: Int, _ field: String) -> String {
            "argument\(index) has the wrong kind of value for \"\(field)\", so it is ignored."
        }

        static func argumentUnknownField(_ index: Int, _ field: String) -> String {
            "argument\(index) has the field \"\(field)\", which this format does not know. It is ignored."
        }

        static func argumentSecure(_ index: Int) -> String {
            "argument\(index) uses \"secure\", which is out of date. Use \"type\": \"password\" instead."
        }

        static func dropdownData(_ index: Int) -> String {
            "argument\(index) is a dropdown, so it needs \"data\": a list of objects with a title and a value."
        }

        static func dataIgnored(_ index: Int) -> String {
            "argument\(index) is not a dropdown, so its \"data\" is ignored."
        }

        static func interpreter(_ line: String) -> String {
            "The first line \"\(line)\" must name the interpreter by its full path, such as #!/bin/bash."
        }

        static let noInterpreter =
            "Add a first line that names the interpreter, such as #!/bin/bash or #!/usr/bin/env python3."

        static let duplicateID = "Another script has the same command ID. Rename one of the files."
    }
}
