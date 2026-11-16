import Kit

/// Every string the host shows, in one place, so localisation has one file to start from.
///
/// Titles of toasts, HUDs, failures, cards, pages and empty states use title case as macOS menus do
/// and end without a full stop. Everything else is a plain sentence.
nonisolated enum HostStrings {
    static let appName = Brand.name
    static let launcherHotkeyOwner = Brand.name
    static let commandUnavailable = "This Command Is Not Available"
    static let commandRefusesLinks = "This Command Cannot Run from a Link"
    static let commandRefusesLinksMessage =
        "A link opened \(Brand.name) this time. Open it yourself, with its hotkey or from the menu bar, "
        + "and run the command from there."
    static let notAnOptionMessage = "Choose one of its options and run the command again."
    static let waitAMoment = "Wait a Moment"
    static let showInLargeType = "Show in Large Type"

    /// Why a held confirm button did nothing yet.
    static func waitBeforeConfirming(_ button: String) -> String {
        "\(button) works once this question has been open for a second."
    }
    static let itemUnavailable = "This Item Is No Longer Available"
    static let searchPlaceholder = "Search for apps and commands"
    static let filterPlaceholder = "Search"
    static let actionsTitle = "Actions"
    static let actionSearchPlaceholder = "Search for actions"
    static let runCommand = "Run Command"
    static let open = "Open"
    /// The toast for a link in a detail that is not a web or mail link. Its message is the target.
    static let notAWebLink = "Not a Web Link"
    static let universalActions = "Universal Actions"
    static let itemActions = "Item"
    static let addToFavorites = "Add to Favorites"
    static let removeFromFavorites = "Remove from Favorites"
    static let setAlias = "Set Alias"
    static let changeAlias = "Change Alias"
    static let setHotkey = "Set Hotkey"
    static let changeHotkey = "Change Hotkey"
    static let resetRanking = "Reset Ranking"
    static let disableCommand = "Disable Command"
    static let addedToFavorites = "Added to Favorites"
    static let removedFromFavorites = "Removed from Favorites"
    static let rankingReset = "Ranking Reset"
    static let commandDisabled = "Command Disabled"
    static let aliasSaved = "Alias Saved"
    static let aliasRemoved = "Alias Removed"
    static let hotkeySaved = "Hotkey Saved"
    static let hotkeyRemoved = "Hotkey Removed"
    static let aliasPlaceholder = "Type an alias, then press Return"
    static let hotkeyPlaceholder = "Press the shortcut, or type one such as opt+cmd+k and press Return"
    static let promptEmptyHint = "Leave it empty to remove it."
    static let notAHotkey = "Not a key combination"
    static let notBuiltYet = "Not Built Yet"
    static let notBuiltYetHint = "This kind of page arrives in a later version."
    static let noResults = "No Results"
    static let dontAskAgain = "Don't ask again"
    static let cancel = "Cancel"
    static let grantAccess = "Grant Access"
    static let openSettings = "Open System Settings"
    static let somethingWentWrong = "Something Went Wrong"
    static let choose = "Choose…"
    static let hotkeyLabel = "Hotkey"
    static let recordShortcut = "Record a shortcut"
    static let applicationPlaceholder = "Choose an app"
    static let share = "Share"
    static let sharingUnavailable = "Sharing Is Not Available Here"
    static let copiedNotPasted = "Copied, Not Pasted"
    static let copiedNotPastedMessage =
        "A link opened \(Brand.name), so nothing was pasted into the app in front. Press Command-V where you want it."

    static func previewPosition(_ name: String, _ position: Int, _ count: Int) -> String {
        "\(name)  \(position) of \(count)"
    }

    /// A dropdown argument got a value that is not one of its options.
    static func notAnOption(_ placeholder: String) -> String {
        "Not an Option for \(titleCased(placeholder, startsTitle: false))"
    }

    static func missingArgument(_ placeholder: String) -> String {
        "Enter \(titleCased(placeholder, startsTitle: false)) First"
    }

    static func permissionTitle(feature: String, permission: String) -> String {
        "\(feature) Needs \(permission)"
    }

    static func permissionStillMissing(_ permission: String) -> String {
        "\(permission) Is Still Missing"
    }

    static func grantInSettings(_ permission: String) -> String {
        "Allow \(permission) in System Settings"
    }

    /// After a grant in System Settings the run does not go ahead by itself, so the title asks
    /// for it again.
    static func grantedRunAgain(_ permission: String, run title: String?) -> String {
        guard let title, !title.isEmpty else { return "\(permission) Allowed, Try Again" }
        return "\(permission) Allowed, Run \(title) Again"
    }

    static func hotkeyTaken(_ owner: String) -> String {
        "Already used by \(owner)"
    }

    static func aliasPromptTitle(_ item: String) -> String {
        "Alias for \(item)"
    }

    static func hotkeyPromptTitle(_ item: String) -> String {
        "Hotkey for \(item)"
    }

    static func currentValue(_ value: String) -> String {
        "Now: \(value)"
    }

    /// Words that stay lowercase inside a title, as in macOS menus: articles, conjunctions and
    /// short prepositions.
    private static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "the",
        "to", "via", "with",
    ]

    /// A feature's text, such as an argument's placeholder, in title case for a title. Each word
    /// starts with a capital except minor words, unless one begins the title; the rest of each word
    /// is kept, so "URL" stays as it is.
    static func titleCased(_ text: String, startsTitle: Bool = true) -> String {
        var words: [String] = []
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let lower = word.lowercased()
            if index > 0 || !startsTitle, minorWords.contains(lower) {
                words.append(lower)
            } else {
                words.append(word.prefix(1).uppercased() + word.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }
}
