/// Every string a user reads, in one place so it can be translated later. Command and action titles
/// use title case, as macOS menus do. Everything else is a plain sentence.
nonisolated enum Strings {
    // MARK: Feature

    static let featureName = "Quicklinks"
    static let selectionReason = "Read the text selected in the frontmost app for links that use {selection}."
    static let featureSummary =
        "Open sites, searches and deep links by name, and search the web when nothing else matches."

    // MARK: Commands

    static let searchQuicklinks = "Search Quicklinks"
    static let createQuicklink = "Create Quicklink"
    static let editQuicklink = "Edit Quicklink"
    static let importQuicklinks = "Import Quicklinks"
    static let exportQuicklinks = "Export Quicklinks"
    static let searchKeywords = ["links", "bookmarks", "web search"]
    static let createKeywords = ["new link", "add link", "custom search"]

    /// The name of a built-in web search, such as "Search Google".
    static func searchSite(_ site: String) -> String { "Search \(site)" }

    /// A fallback row under root results.
    static func fallbackTitle(_ name: String, _ text: String) -> String { "\(name) for \"\(text)\"" }

    // MARK: Actions

    static let open = "Open"
    static let openWith = "Open With"
    static let copyLink = "Copy Link"
    static let edit = "Edit Quicklink"
    static let duplicate = "Duplicate Quicklink"
    static let delete = "Delete Quicklink"
    static let turnOff = "Turn Off Quicklink"
    static let turnOn = "Turn On Quicklink"
    static let setAsDefault = "Set as Default Search Engine"
    static let saveAsQuicklink = "Save as Quicklink"
    static let searchTheWeb = "Search the Web"
    static let searchWith = "Search With"
    static let openLink = "Open Link"
    static let manageSection = "Manage"

    // MARK: Confirmations

    static func deleteTitle(_ name: String) -> String { "Delete \"\(name)\"?" }
    static let deleteBuiltInMessage = "Restore Default Searches in settings brings it back."
    static let deleteOwnMessage = "This cannot be undone."
    static let deleteConfirm = "Delete"
    static let restoreTitle = "Restore the default web searches?"
    static let restoreMessage =
        "Deleted web searches come back and edited ones return to how they were. Your own quicklinks stay as they are."
    static let restoreConfirm = "Restore"

    // MARK: Toasts and HUDs

    static let copiedLink = "Copied Link"
    static let savedQuicklink = "Saved quicklink"
    static let deletedQuicklink = "Deleted quicklink"
    static func turnedOff(_ name: String) -> String { "\(name) is off" }
    static func turnedOn(_ name: String) -> String { "\(name) is on" }
    static func defaultEngineSet(_ name: String) -> String { "\(name) is the default search engine" }
    static let restoredDefaults = "Restored the default web searches"
    static func imported(_ count: Int) -> String {
        count == 1 ? "Imported 1 quicklink" : "Imported \(count) quicklinks"
    }
    static func importSkipped(duplicates: Int, invalid: Int) -> String? {
        var parts: [String] = []
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 duplicate" : "\(duplicates) duplicates") }
        if invalid > 0 {
            parts.append(invalid == 1 ? "1 entry that was not valid" : "\(invalid) entries that were not valid")
        }
        guard !parts.isEmpty else { return nil }
        return "Skipped " + parts.joined(separator: " and ") + "."
    }
    static func exported(_ count: Int) -> String {
        count == 1 ? "Exported 1 quicklink" : "Exported \(count) quicklinks"
    }

    // MARK: Errors

    static func linkNotValid(_ name: String) -> String { "\(name) did not make a valid link" }
    static let linkNotValidMessage = "Edit the quicklink and check its link."
    static let linkNotWeb = "The text that starts this link is not a web address, so it was not opened."
    static let linkSchemeChanged = "A value changed what kind of link this is, so it was not opened."
    static let couldNotOpen = "Could not open the link"
    static let fileUnreadableTitle = "The quicklinks file could not be read"
    static let fileUnreadableMessage =
        "Fix the file or delete it to start over. Changes are not saved until then."
    static let importUnreadable = "The file is not a quicklinks export"
    static let importUnreadableMessage = "Choose a JSON file with a list of quicklinks, each with a name and a link."
    static let importTooLarge = "The file is too large to import"
    static let noSearchEngine = "No web search is turned on"
    static let noSearchEngineMessage = "Turn on a web search in Search Quicklinks."
    static let quicklinkGone = "This quicklink no longer exists"

    // MARK: List

    static let searchPlaceholder = "Search quicklinks"
    static let editPlaceholder = "Choose a quicklink to edit"
    static let ownSection = "My Quicklinks"
    static let builtInSection = "Web Searches"
    static let filterTitle = "Show"
    static let filterAll = "All Quicklinks"
    static let filterOwn = "My Quicklinks"
    static let filterBuiltIn = "Web Searches"
    static let filterOff = "Turned Off"
    static let offTag = "Off"
    static let defaultTag = "Default"
    static let fallbackTooltip = "Offered when nothing else matches"
    static let emptyTitle = "No Quicklinks"
    static let emptyMessage = "Create a quicklink, or restore the default web searches in settings."
    static let untitled = "Untitled Quicklink"

    // MARK: Detail

    static let detailKeywords = "Keywords"
    static let detailOpensWith = "Opens with"
    static let detailDefaultApp = "Default app"
    static let detailArguments = "Arguments"
    static let detailFallback = "When nothing matches"
    static let detailFallbackOn = "Offered"
    static let detailFallbackOff = "Not offered"
    static let detailStatus = "Status"
    static let detailOn = "On"
    static let detailOff = "Off"
    static let argumentFallbackName = "Argument"

    // MARK: Forms

    static let nameField = "Name"
    static let namePlaceholder = "Search Docs"
    static let linkField = "Link"
    static let linkPlaceholder = "https://example.com/search?q={argument name=\"Query\"}"
    static let linkInfo =
        "Add {argument name=\"Query\"} where typed text goes, or {query} for short. Up to three arguments show as fields in the search bar."
    static let keywordsField = "Keywords"
    static let keywordsInfo = "Short words that find this quicklink, such as gh for GitHub."
    static let openWithField = "Open With"
    static let openWithInfo = "Leave empty to use the default app."
    static let iconField = "Icon"
    static let fallbackField = "Fallback"
    static let fallbackLabel = "Offer when nothing else matches"
    static let saveQuicklink = "Save Quicklink"
    static let openSubmit = "Open"
    static func copyName(_ name: String) -> String { "\(name) Copy" }

    static let nameTooLong = "Use a shorter name, up to 100 characters."
    static let linkOneLine = "A link is one line."
    static let linkTooLong = "This link is too long."
    static func placeholderMistake(_ detail: String) -> String { "Fix this placeholder: \(detail)." }
    static let linkNeedsScheme = "Enter a full link, such as https://example.com."
    static let linkNeedsHost = "Add the site's address after https://."
    static let linkNotParsed = "This is not a link that can be opened."
    static let keywordOneWord = "Each keyword is one word."
    static let keywordTooLong = "Use shorter keywords, up to 32 characters."

    // MARK: Icons

    static let iconWebsite = "Website Icon"
    static let iconChoices: [(symbol: String, title: String)] = [
        ("link", "Link"), ("magnifyingglass", "Search"), ("globe", "Globe"), ("book", "Book"),
        ("doc.text", "Document"), ("folder", "Folder"), ("star", "Star"), ("bolt", "Bolt"),
        ("terminal", "Terminal"), ("cart", "Cart"), ("map", "Map"), ("play.rectangle", "Video"),
        ("person.2", "People"), ("chevron.left.forwardslash.chevron.right", "Code"),
    ]

    // MARK: Root search

    static func openAddress(_ address: String) -> String { "Open \(address)" }

    // MARK: Dialogs

    static let importDialogTitle = "Import Quicklinks"
    static let exportDialogTitle = "Export Quicklinks"
    static let exportFileName = "Quicklinks.json"

    // MARK: Settings

    static let webSearchSection = "Web Search"
    static let quicklinksSection = "Quicklinks"
    static let defaultEngineSetting = "Default search engine"
    static let defaultEngineInfo = "Used by Search the Web, and offered first when nothing else matches."
    static let fallbacksSetting = "Offer web searches when nothing matches"
    static let fallbacksInfo = "The default search engine comes first. Turn on Fallback for any other search."
    static let addressesSetting = "Open typed web addresses"
    static let addressesInfo = "Typing an address such as example.com offers to open it."
    static let restoreButton = "Restore Default Searches"
    static let restoreInfo = "Brings back the built-in web searches as they first were."
    static let revealButton = "Show Quicklinks File in Finder"
    static let revealInfo = "The file is plain JSON. Changes you save to it apply at once."

    // MARK: Status

    static let statusUnreadable = "The quicklinks file could not be read"
    static let statusUnreadableMessage =
        "Fix the file or delete it to start over. New changes are not saved until then."
}
