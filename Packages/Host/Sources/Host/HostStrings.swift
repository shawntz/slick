import Kit

/// Every string the host shows, in one place, so localisation has one file to start from.
nonisolated enum HostStrings {
    static let appName = Brand.name
    static let launcherHotkeyOwner = Brand.name
    static let commandUnavailable = "This command is not available"
    static let itemUnavailable = "This item is no longer available"
    static let searchPlaceholder = "Search for apps and commands"
    static let filterPlaceholder = "Search"
    static let actionsTitle = "Actions"
    static let actionSearchPlaceholder = "Search for actions"
    static let runCommand = "Run Command"
    static let open = "Open"
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
    static let notBuiltYet = "Not built yet"
    static let notBuiltYetHint = "This kind of page arrives in a later version."
    static let noResults = "No Results"
    static let dontAskAgain = "Don't ask again"
    static let cancel = "Cancel"
    static let grantAccess = "Grant Access"
    static let openSettings = "Open System Settings"
    static let somethingWentWrong = "Something went wrong"
    static let choose = "Choose…"
    static let hotkeyLabel = "Hotkey"
    static let recordShortcut = "Record a shortcut"
    static let bundleIDPlaceholder = "Bundle ID"
    static let share = "Share"
    static let sharingUnavailable = "Sharing is not available here"

    static func previewPosition(_ name: String, _ position: Int, _ count: Int) -> String {
        "\(name)  \(position) of \(count)"
    }

    static func missingArgument(_ placeholder: String) -> String {
        "Enter \(placeholder) first"
    }

    static func permissionTitle(feature: String, permission: String) -> String {
        "\(feature) needs \(permission)"
    }

    static func permissionStillMissing(_ permission: String) -> String {
        "\(permission) is still missing"
    }

    static func grantInSettings(_ permission: String) -> String {
        "Allow \(permission) in System Settings, then try again"
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
}
