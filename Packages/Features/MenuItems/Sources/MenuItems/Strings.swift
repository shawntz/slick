/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Everything else is a plain sentence. Menu and item titles come from
/// the app being searched and are shown as that app wrote them.
nonisolated enum Strings {
    // MARK: - The feature

    static let featureName = "Menu Items"
    static let summary = "Search the menus of the app you were using and run any menu item from the keyboard."
    static let accessibilityReason =
        "Read the menu bar of the app you were using, and press the menu item you choose."

    // MARK: - The command

    static let searchMenuItems = "Search Menu Items"
    static let keywords = ["menu", "menu bar", "menus", "commands", "shortcuts", "keyboard shortcuts"]

    static func placeholder(_ app: String) -> String {
        "Search the menus of \(app)"
    }

    static let noAppTitle = "No App to Search"
    static let noAppMessage = "Open an app first, then search its menu items."

    static func leftOutTitle(_ app: String) -> String {
        "\(app) Is Left Out"
    }

    static let leftOutMessage = "Its menus are not read. You can change this in settings."

    // MARK: - Rows

    /// The separator between the menus on the way to an item, as in "File › Export".
    static let pathSeparator = " › "

    static func path(_ menus: [String]) -> String {
        menus.joined(separator: pathSeparator)
    }

    /// The subtitle while Option is held over an item that has an Option alternate.
    static func optionSubtitle(_ alternate: String) -> String {
        "Return runs “\(alternate)”."
    }

    static let unavailableTag = "Unavailable"
    static let checkedTooltip = "Checked"
    static let mixedTooltip = "Partly checked"

    // MARK: - Actions

    static let runItem = "Run Menu Item"

    static func runAlternate(_ title: String) -> String {
        "Run “\(title)”"
    }

    static let readAgain = "Read Menus Again"
    static let grantAccess = "Grant Access"

    static let unavailableTitle = "Menu Item Unavailable"

    static func unavailableMessage(_ app: String) -> String {
        "\(app) had turned this menu item off. Read the menus again if that has changed."
    }

    static func couldNotRun(_ title: String) -> String {
        "Could Not Run “\(title)”"
    }

    static func appGoneMessage(_ app: String) -> String {
        "\(app) is no longer open."
    }

    static func itemGoneMessage(_ app: String) -> String {
        "\(app) no longer shows this menu item. Read the menus again to see what it shows now."
    }

    static func itemDisabledMessage(_ app: String) -> String {
        "\(app) has turned this menu item off."
    }

    static func notAnsweringMessage(_ app: String) -> String {
        "\(app) did not answer. Try again in a moment."
    }

    static let needsAccessTitle = "Menu Search Needs Accessibility"
    static let needsAccessMessage = "Grant Accessibility to read the menus of other apps."
    static let needsAccessPressMessage = "Grant Accessibility in System Settings, then try again."

    // MARK: - Empty states and notices

    static let readingTitle = "Reading Menus"

    static func readingMessage(_ app: String) -> String {
        "Reading the menu bar of \(app)."
    }

    static let noItemsTitle = "No Menu Items"

    static func noItemsMessage(_ app: String) -> String {
        "\(app) shows no menu items."
    }

    static func allHiddenMessage(_ app: String) -> String {
        "Every menu item of \(app) is turned off or in the Apple menu. You can show those in settings."
    }

    static let noMatchesTitle = "No Matching Menu Items"

    static func noMatchesMessage(_ app: String) -> String {
        "No menu item of \(app) matches your search."
    }

    static func appGoneTitle(_ app: String) -> String {
        "\(app) Is Not Open"
    }

    static let appGoneHint = "Open it again to search its menu items."

    static let noMenuBarTitle = "No Menu Bar"

    static func noMenuBarMessage(_ app: String) -> String {
        "\(app) does not show a menu bar to search."
    }

    static func notAnsweringTitle(_ app: String) -> String {
        "\(app) Did Not Answer"
    }

    static let someMissingTitle = "Some Menu Items Are Missing"

    /// `limit` is a formatted duration, such as "3 seconds".
    static func timedOutMessage(_ app: String, limit: String) -> String {
        "\(app) answered slowly, so the list stops at what it read in \(limit)."
    }

    /// `limit` is a formatted number, such as "20,000".
    static func tooManyMessage(_ limit: String) -> String {
        "The list stops at \(limit) menu items."
    }

    static func deepMenusMessage(_ depth: Int) -> String {
        "Menus nested more than \(depth) levels deep are left out."
    }

    static let outOfDateTitle = "These Menu Items May Be Out of Date"

    // MARK: - Settings

    static let showSection = "Show"
    static let showsDisabledItems = "Show menu items the app has turned off"
    static let showsDisabledItemsInfo =
        "They are marked as unavailable. Running one does nothing until the app turns it on."
    static let showsAppleMenu = "Show the Apple menu"
    static let showsAppleMenuInfo = "Adds items such as System Settings, Sleep, Restart and Log Out to every list."

    static let appsSection = "Apps"
    static let leftOutApps = "Apps to leave out"
    static let leftOutAppsInfo = "Search Menu Items never reads the menus of these apps."

    static let accessSection = "Access"
    static let accessInfo =
        "Reading another app's menus needs Accessibility. Nothing asks for it until you run Search Menu Items and press Grant."

    static let privacySection = "Privacy"
    static let storageNote =
        "Menus are read only when you run Search Menu Items. They are kept in memory until the launcher quits, so the next search of the same app shows at once, and are never written to disk."
    static let networkNote = "This feature sends nothing over the network."
}
