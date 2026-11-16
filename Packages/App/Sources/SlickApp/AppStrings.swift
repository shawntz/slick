import Kit

/// Every string the app itself shows a person.
enum AppStrings {
    // MARK: Menu bar item

    static var openLauncher: String { "Open \(Brand.name)" }
    static let settings = "Settings…"
    static var quit: String { "Quit \(Brand.name)" }
    /// Opens the updater's window, which checks and shows the result.
    static let checkForUpdates = "Check for Updates…"
    /// Leads the menu while an update a scheduled check found waits. It opens the updater's window.
    static func updateWaiting(_ version: String) -> String { "Update to \(Brand.name) \(version)…" }

    // MARK: Deep links

    static let linkPageTitle = "Open Link"
    static let linkSection = "A link asks to run this command"
    static func linkRunOnce(_ title: String) -> String { "Run \(title)" }
    static let linkAlwaysAllow = "Always Allow"
    /// What Always Allow allows: the command with no arguments, or with exactly the ones shown.
    static func linkAlwaysAllowDetail(_ title: String, hasArguments: Bool) -> String {
        hasArguments
            ? "Run \(title) from links with exactly these arguments, without asking"
            : "Run \(title) from links with no arguments, without asking"
    }
    static let linkCancel = "Cancel"
    static let linkWait = "Wait a Moment"
    static let linkWaitMessage = "Run and Always Allow work once this page has been open for a second."

    static let linkArgumentsSection = "Arguments"

    /// Under Run: how many arguments the link passes. Each has a row of its own below.
    static func linkArgumentCount(_ count: Int) -> String {
        switch count {
        case 0: "With no arguments"
        case 1: "With the argument listed below"
        default: "With the \(count) arguments listed below"
        }
    }

    /// An argument row's subtitle: its value, or a note that it is empty.
    static func linkArgumentValue(_ value: String) -> String {
        value.isEmpty ? "Empty" : value
    }

    /// The detail pane beside the page: every argument the command will get, in full, one
    /// paragraph each, ordered by name.
    static func linkArgumentsInFull(_ title: String, arguments: [String: String]) -> String {
        let parts = arguments.keys.sorted().map { name in
            let value = arguments[name] ?? ""
            return value.isEmpty ? "\(name) is empty." : "\(name): \(value)"
        }
        return (["\(title) gets exactly these arguments."] + parts).joined(separator: "\n\n")
    }

    // MARK: Problems

    static var dataFolderInUse: String {
        "Another copy of \(Brand.name) uses the data folder. This copy forgets what it learns when it quits."
    }
    static var dataFolderUnusable: String {
        "\(Brand.name) cannot write to the data folder. It forgets what it learns when it quits."
    }
    /// A HUD title, so title case: the combination, as `KeyCombo.displayString` writes it.
    static func hotkeyRefused(_ combo: String) -> String {
        "Launcher Hotkey \(combo) Is Taken"
    }
    static var alreadyRunning: String {
        "\(Brand.name) is already running. Opening it there."
    }
}
