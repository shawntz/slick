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
    static func linkAlwaysAllowDetail(_ title: String) -> String {
        "Run \(title) from links from now on without asking"
    }
    static let linkCancel = "Cancel"

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
    static func hotkeyRefused(_ combo: String) -> String {
        "The launcher hotkey \(combo) is taken. Choose another in Settings."
    }
    static var alreadyRunning: String {
        "\(Brand.name) is already running. Opening it there."
    }
}
