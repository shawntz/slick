import Kit
import KitTemplates

/// Every string a user reads, in one place so it can be translated later. Command and action titles
/// use title case, as macOS menus do. Everything else is a plain sentence.
nonisolated enum Strings {
    // MARK: Feature

    static let featureName = "Snippets"
    static let featureSummary =
        "Save text you type often, then paste it from the search field or type its keyword in any app."
    static let accessibilityReason = "Paste snippets into the app you are using and replace typed keywords with text."
    static let inputMonitoringReason = "Notice when you type a snippet's keyword in any app."

    // MARK: Commands

    static let searchCommand = "Search Snippets"
    static let createCommand = "Create Snippet"
    static let editCommand = "Edit Snippet"
    static let fillCommand = "Fill In Snippet"
    static let importCommand = "Import Snippets"
    static let exportCommand = "Export Snippets"
    static let turnOnCommand = "Turn On Snippet Expansion"
    static let turnOffCommand = "Turn Off Snippet Expansion"
    static let searchKeywords = ["snippet", "text", "expand", "keyword", "template"]
    static let expansionKeywords = ["snippet", "keyword", "text expansion"]

    // MARK: List

    static let searchPlaceholder = "Search snippets"
    static let pinnedSection = "Pinned"
    static let snippetsSection = "Snippets"
    static let collectionFilter = "Collection"
    static let allSnippets = "All Snippets"
    static let emptyTitle = "No Snippets"
    static let emptyMessage = "Save text you type often. Paste it from here, or type its keyword in any app."
    static let unreadableTitle = "Your snippets could not be read"
    static func unreadableMessage(_ fileName: String) -> String {
        "Fix or remove \(fileName) in the snippets folder. Changes are not saved until then."
    }
    static func expansionNotice(_ permission: Permission) -> String {
        "Keywords do not expand until you allow \(permission.displayName)."
    }
    static func allowAction(_ permission: Permission) -> String {
        "Allow \(permission.displayName)"
    }

    // MARK: Detail

    static let keywordLabel = "Keyword"
    static let collectionLabel = "Collection"
    static let expansionLabel = "Expansion"
    static let expandsValue = "When the keyword is typed"
    static let doesNotExpandValue = "Off for this snippet"
    static let placeholdersLabel = "Placeholders"
    static let problemLabel = "Problem"
    static let includedByLabel = "Included by"
    static let usedLabel = "Used"
    static let createdLabel = "Created"
    static let modifiedLabel = "Modified"
    /// A placeholder's tag in the detail pane: its name as people write it, such as "clipboard", with
    /// the argument's or included snippet's name.
    static func placeholderTag(_ kind: PlaceholderKind) -> String {
        switch kind {
        case .clipboard(let offset): offset == 0 ? "clipboard" : "clipboard \(offset)"
        case .selection: "selection"
        case .date(let style, _): style.rawValue
        case .uuid: "uuid"
        case .cursor: "cursor"
        case .argument(let argument): argument.name.map { "argument: " + $0 } ?? "argument"
        case .snippet(let name): "snippet: " + name
        }
    }
    static func useCount(_ count: Int) -> String {
        switch count {
        case 0: "Never"
        case 1: "Once"
        default: "\(count) times"
        }
    }

    // MARK: Actions

    static let pasteAction = "Paste Snippet"
    static let copyAction = "Copy to Clipboard"
    static let copiedHUD = "Copied to Clipboard"
    static let editAction = "Edit Snippet"
    static let duplicateAction = "Duplicate Snippet"
    static let pinAction = "Pin Snippet"
    static let unpinAction = "Unpin Snippet"
    static let createAction = "Create Snippet"
    static let deleteAction = "Delete Snippet"
    static let showFileAction = "Show Snippets File in Finder"
    static let snippetSection = "Snippet"
    static let librarySection = "Library"
    static func deleteQuestion(_ name: String) -> String {
        "Delete \"\(name)\"?"
    }
    static func deleteMessage(includedBy names: [String]) -> String {
        guard !names.isEmpty else { return "You cannot undo this." }
        let verb = names.count == 1 ? "includes" : "include"
        return "You cannot undo this. \(list(names)) \(verb) it, and will insert nothing in its place."
    }
    static let deleteConfirm = "Delete"
    static func pinned(_ name: String) -> String { "Pinned \(name)" }
    static func unpinned(_ name: String) -> String { "Unpinned \(name)" }
    static func deleted(_ name: String) -> String { "Deleted \(name)" }
    static func saved(_ name: String) -> String { "Saved \(name)" }
    static let snippetGone = "This snippet no longer exists"

    // MARK: Forms

    static let nameField = "Name"
    static let namePlaceholder = "Email signature"
    static let textField = "Snippet"
    static let textPlaceholder = "Text to paste, with {placeholders}"
    static let textInfo =
        "Placeholders fill in when you paste: {date}, {time}, {clipboard}, {cursor}, {uuid}, "
        + "{argument name=\"...\"} and {snippet name=\"...\"}."
    static let keywordField = "Keyword"
    static let keywordPlaceholder = "sig"
    static func keywordInfo(prefix: String) -> String {
        prefix.isEmpty
            ? "Type it in any app to insert the snippet, once expansion is on in settings."
            : "Type \(prefix) and then the keyword in any app to insert the snippet."
    }
    static let collectionField = "Collection"
    static let collectionPlaceholder = "None"
    static func collectionInfo(existing: [String]) -> String {
        existing.isEmpty
            ? "Groups related snippets, such as Email or Code."
            : "Groups related snippets. You have \(list(existing))."
    }
    static let expandsField = "Expansion"
    static let expandsCheckbox = "Expand when the keyword is typed"
    static let createSubmit = "Create Snippet"
    static let saveSubmit = "Save Snippet"
    static let pasteSubmit = "Paste Snippet"
    static let copySubmit = "Copy Snippet"
    static func argumentField(_ position: Int) -> String { "Argument \(position)" }
    static func argumentsInfo(_ name: String) -> String {
        "Fill these in to finish \(name)."
    }
    static func pasteInfo(_ name: String) -> String {
        "Paste \(name) into the app you were using."
    }
    static let untitledName = "New Snippet"
    static func copyName(_ name: String) -> String { "\(name) Copy" }
    static func numberedName(_ name: String, _ number: Int) -> String { "\(name) \(number)" }

    // MARK: Validation

    static let nameTaken =
        "Another snippet already has this name. Pick a different one, so {snippet} placeholders find the right text."
    static func placeholderProblem(_ message: String) -> String {
        "This placeholder has a problem: \(message)."
    }
    static let includesItself = "A snippet cannot include itself."
    static func noSnippetNamed(_ name: String) -> String {
        "No snippet is called \"\(name)\"."
    }
    static let cursorTwice = "Use {cursor} only once. The insertion point goes to the first one."
    static func textTooLong(_ limit: Int) -> String {
        "A snippet can hold up to \(limit) characters."
    }
    static let keywordHasSpace = "A keyword cannot contain spaces or line breaks."
    static let keywordTooShort =
        "Use at least two characters, or set a keyword prefix in settings, so ordinary typing does not expand it."
    static func keywordTaken(by name: String) -> String {
        "\"\(name)\" already uses this keyword."
    }
    static func keywordShadowed(by name: String, keyword: String) -> String {
        "\"\(name)\" expands as soon as you type \"\(keyword)\", so this keyword could never be finished. "
            + "Pick one that does not start with \"\(keyword)\"."
    }
    static func keywordShadows(_ name: String, keyword: String) -> String {
        "This keyword would expand before you could finish \"\(keyword)\", the keyword of \"\(name)\". "
            + "Pick one that is not the start of \"\(keyword)\"."
    }

    // MARK: Saving

    static let readOnlyTitle = "Snippets cannot be saved right now"
    static let readOnlyMessage = "The snippets file could not be read. Fix or remove it first."
    static let newerFileTitle = "Your snippets file is from a newer version"
    static let newerFileMessage = "Your snippets work, but changes are not saved, so nothing in the file is lost."
    static let newerFileReadOnlyMessage = "The snippets file is from a newer version. Update to make changes."

    // MARK: Import and export

    static let importDialog = "Import Snippets"
    static let exportDialog = "Export Snippets"
    static let exportFileName = "Snippets.json"
    static func importFailed(_ fileName: String) -> String { "Could not import \(fileName)" }
    static let importFailedMessage = "It is not a snippets file. Nothing was imported."
    static func imported(_ count: Int) -> String {
        count == 0 ? "No new snippets to import" : "Imported \(snippets(count))"
    }
    static func importNotes(
        duplicates: Int, keywordClashes: Int, incomplete: Int, renamed: Int, keywordsLeftOut: Int
    ) -> String? {
        var notes: [String] = []
        if duplicates > 0 { notes.append("Skipped \(snippets(duplicates)) you already have.") }
        if keywordClashes > 0 {
            notes.append("Skipped \(snippets(keywordClashes)) whose keyword another snippet uses.")
        }
        if incomplete > 0 { notes.append("Skipped \(entries(incomplete)) without a name or text.") }
        if renamed > 0 { notes.append("Renamed \(snippets(renamed)) whose name was taken.") }
        if keywordsLeftOut > 0 {
            notes.append(
                "Imported \(snippets(keywordsLeftOut)) without a keyword, because it was too short, "
                    + "had a space or would stop another keyword from expanding.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
    static func exported(_ count: Int) -> String { "Exported \(snippets(count))" }
    static let nothingToExport = "There are no snippets to export"

    // MARK: Expansion

    static let expansionOn = "Snippet expansion is on"
    static let expansionOff = "Snippet expansion is off"
    static func expansionNeeds(_ permission: Permission) -> String {
        "Snippet expansion needs \(permission.displayName)"
    }
    static let expansionNeedsMessage = "Keywords do not expand until you allow it."
    static func secureInput(_ owner: String?) -> String {
        "Snippet expansion is paused while \(owner ?? "another app") has secure input on"
    }
    static let secureInputMessage = "Keywords expand again when it ends, for example when you leave a password field."

    // MARK: Universal action

    static let saveAsSnippet = "Save as Snippet"

    // MARK: Settings

    static let expansionSection = "Text Expansion"
    static let expandToggle = "Expand keywords as you type"
    static let expandToggleInfo = "Off until you turn it on. It needs Input Monitoring and Accessibility."
    static let triggerPicker = "Expand"
    static let triggerImmediately = "As soon as the keyword is typed"
    static let triggerAfterDelimiter = "After a space, return or punctuation mark"
    static let prefixField = "Keyword prefix"
    static let prefixPlaceholder = "None"
    static let prefixInfo =
        "Typed before every keyword. With the prefix \";\", the keyword \"sig\" expands when you type \";sig\"."
    static let withinWordsToggle = "Expand inside words"
    static let withinWordsInfo = "When this is off, a keyword expands only at the start of a word."
    static let excludedAppsList = "Never expand in"
    static let excludedAppsInfo = "Password managers are on this list at first."
    static let inputMonitoringInfo = "Lets the feature notice a keyword as you type it."
    static let accessibilityInfo = "Lets the feature replace the keyword and paste snippets."
    static let searchSection = "Search"
    static let rootToggle = "Show snippets in root search"
    static let rootToggleInfo =
        "Find a snippet by name from the main search field. A full keyword shows its snippet first."
    static let orderPicker = "Sort snippets by"
    static let orderName = "Name"
    static let orderFrequency = "Most used"
    static let filesSection = "Files"
    static let showFileInfo = "Snippets live in one JSON file. Changes you make to it by hand show up at once."

    // MARK: Starter snippets

    static let starterCollection = "Examples"
    static let starterDate = "Today's Date"
    static let starterTime = "Current Time"
    static let starterTimestamp = "Timestamp"
    static let starterUUID = "New UUID"
    static let starterReply = "Thank You Reply"
    static let starterReplyText = "Hi {argument name=\"name\"},\n\nThank you for your message. {cursor}\n\nBest regards"

    // MARK: Counted nouns

    static func snippets(_ count: Int) -> String {
        count == 1 ? "1 snippet" : "\(count) snippets"
    }

    static func entries(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// "A", "A and B", "A, B and C", quoted.
    static func list(_ names: [String]) -> String {
        let quoted = names.map { "\"\($0)\"" }
        guard let last = quoted.last else { return "" }
        guard quoted.count > 1 else { return last }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }
}
