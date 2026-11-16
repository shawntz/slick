import Kit

/// Every string the app itself shows a person.
enum AppStrings {
    // MARK: Menu bar item

    static var openLauncher: String { "Open \(Brand.name)" }
    static let settings = "Settings…"
    static var quit: String { "Quit \(Brand.name)" }

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

    /// The arguments a link passes, as one line, or a note that it passes none.
    static func linkArguments(_ arguments: [String: String]) -> String {
        guard !arguments.isEmpty else { return "With no arguments" }
        let parts = arguments.keys.sorted().map { "\($0): \(arguments[$0] ?? "")" }
        return "With " + parts.joined(separator: ", ")
    }

    // MARK: Problems

    static var dataFolderInUse: String {
        "Another copy of \(Brand.name) is using the data folder. Learning is not saved until it quits."
    }
    static var dataFolderUnusable: String {
        "The data folder cannot be written. Learning is not saved."
    }
    /// A HUD title, so title case: the combination, as `KeyCombo.displayString` writes it.
    static func hotkeyRefused(_ combo: String) -> String {
        "Launcher Hotkey \(combo) Is Taken"
    }
    static var alreadyRunning: String {
        "\(Brand.name) is already running. Opening it there."
    }
}
