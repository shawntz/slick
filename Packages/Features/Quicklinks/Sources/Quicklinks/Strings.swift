import Kit

/// Every string a user reads, in one place so it can be translated later. Command, action, section,
/// empty-state, toast and HUD titles, buttons and menu items use title case, as macOS menus do.
/// Everything else is a plain sentence.
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
    static let savedQuicklink = "Saved Quicklink"
    static let deletedQuicklink = "Deleted Quicklink"
    static func turnedOff(_ name: String) -> String { "\(name) Is Off" }
    static func turnedOn(_ name: String) -> String { "\(name) Is On" }
    static func defaultEngineSet(_ name: String) -> String { "\(name) Is the Default Search Engine" }
    static let restoredDefaults = "Restored the Default Web Searches"
    static func imported(_ count: Int) -> String {
        switch count {
        case 0: "No New Quicklinks to Import"
        case 1: "Imported 1 Quicklink"
        default: "Imported \(count) Quicklinks"
        }
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
    /// What an import added, turned off and skipped: a success toast, or a plain one when nothing
    /// was new.
    static func importToast(_ plan: QuicklinkImportPlan) -> Toast {
        var notes: [String] = []
        if plan.turnedOff > 0 {
            notes.append(
                plan.turnedOff == 1
                    ? "Turned 1 off, because its link is not a web link."
                    : "Turned \(plan.turnedOff) off, because their links are not web links.")
        }
        if plan.turnedOffSending > 0 {
            notes.append(
                plan.turnedOffSending == 1
                    ? "Turned 1 off, because its link sends what you copied or selected."
                    : "Turned \(plan.turnedOffSending) off, because their links send what you copied or selected.")
        }
        if let skipped = importSkipped(duplicates: plan.duplicates, invalid: plan.invalid) { notes.append(skipped) }
        return Toast(
            plan.added > 0 ? .success : .info, imported(plan.added),
            message: notes.isEmpty ? nil : notes.joined(separator: " "))
    }
    static func exported(_ count: Int) -> String {
        count == 1 ? "Exported 1 Quicklink" : "Exported \(count) Quicklinks"
    }

    // MARK: Errors

    static func linkNotValid(_ name: String) -> String { "\(name) Did Not Make a Valid Link" }
    static let linkNotValidMessage = "Edit the quicklink and check its link."
    static let linkNotWeb = "The text that starts this link is not a web address, so it was not opened."
    static let linkSchemeChanged = "A value changed what kind of link this is, so it was not opened."
    static let couldNotOpen = "Could Not Open the Link"
    static let fileUnreadableTitle = "The Quicklinks File Could Not Be Read"
    static let fileUnreadableMessage =
        "Fix the file or delete it to start over. Changes are not saved until then."
    static let importUnreadable = "The File Is Not a Quicklinks Export"
    static let importUnreadableMessage = "Choose a JSON file with a list of quicklinks, each with a name and a link."
    static let importTooLarge = "The File Is Too Large to Import"
    static let noSearchEngine = "No Web Search Is Turned On"
    static let noSearchEngineMessage = "Turn on a web search in Search Quicklinks."
    static let quicklinkGone = "This Quicklink No Longer Exists"

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

    // MARK: Import page

    static let importSubtitle =
        "From Raycast, a \(Brand.name) export, or Alfred web searches. The Alfred format is unverified."
    static let importKeywords = ["raycast", "alfred", "web searches", "json", "migrate"]
    static let exportKeywords = ["raycast", "json", "backup"]
    static func importAction(_ count: Int) -> String {
        count == 1 ? "Import 1 Quicklink" : "Import \(count) Quicklinks"
    }
    static let importPageTitle = "Import Quicklinks"
    static let importSearchPlaceholder = "Search what will be imported"
    static let importNoticeTitle = "Nothing Is Saved Until You Import"
    static func importNoticeMessage(_ count: Int) -> String {
        "Choose \(importAction(count)) to add them, or go back to cancel."
    }
    static let importAddSection = "To Add"
    static let importOffSection = "To Add Turned Off"
    static let importDuplicateSection = "Skipped as Duplicates"
    static let importNotValidSection = "Skipped as Not Valid"
    static let importOutcomeLabel = "Import"
    static func entryTitle(_ position: Int) -> String { "Entry \(position)" }
    static let importNoName = "It has no name."
    static let importNoLink = "It has no link."
    static let importTooMany = "The file holds more than 10,000 entries, and this one is past that."
    static func importTurnedOff(_ scheme: String) -> String {
        "Turned off, because it opens a \(DisplayText.fileName(scheme, limit: 20)) link, not a web page. "
            + "Check it, then turn it on."
    }
    static func importTurnedOffSending(clipboard: Bool, selection: Bool) -> String {
        let what =
            switch (clipboard, selection) {
            case (true, true): "what you copied and selected"
            case (true, false): "what you copied"
            default: "what you selected"
            }
        return "Turned off, because it sends \(what) to the site it opens. Check it, then turn it on."
    }
    static func importDuplicate(of name: String) -> String {
        "\u{201C}\(name)\u{201D} already has this name and link."
    }
    static func importUnknownApp(_ app: String) -> String {
        "Opens in your default app. The file names \u{201C}\(DisplayText.fileName(app, limit: 40))\u{201D}, "
            + "which is not an app ID."
    }

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
