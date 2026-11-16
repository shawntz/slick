import Darwin
import Foundation
import Kit

/// Every string a person reads in this feature, in one place.
///
/// Command, action, section, empty-state, toast, notice and HUD titles, buttons and menu items use
/// title case and end without a full stop. Everything else is a plain sentence that says what will
/// happen or what happened. A note's title or a file name that someone else chose goes through
/// `DisplayText` before it reaches any of these, and is quoted with curly quotes.
nonisolated enum Strings {
    static let featureName = "Notes"
    static let featureSummary =
        "Write quick notes as Markdown files that any editor opens, then find, edit and paste them."
    static let accessibilityReason = "Paste a note into the app you were using."
    static let untitledNote = "Untitled Note"

    // MARK: Commands

    static let searchCommand = "Search Notes"
    static let searchKeywords = ["notes", "markdown", "memo", "find note"]
    static let createCommand = "Create Note"
    static let createKeywords = ["new note", "write", "markdown", "memo"]
    static let appendCommand = "Append to Note"
    static let appendKeywords = ["add to note", "notes"]
    static let textPlaceholder = "Text"
    static let searchPlaceholder = "Search notes"
    static let pickerPlaceholder = "Choose a note"

    // MARK: List

    static let pinnedSection = "Pinned"
    static let titleMatchesSection = "Matching Titles"
    static let textMatchesSection = "Matching Text"
    static let emptyTitle = "No Notes Yet"
    static let emptyMessage = "Notes you create are kept as Markdown files that any editor can open."
    static let noMatchesTitle = "No Matching Notes"
    static let noMatchesMessage = "Try other words, or create a note with what you typed."
    static let notReadTitle = "No Notes to Show"
    static let pickerEmptyTitle = "No Notes to Append To"
    static let pickerEmptyMessage = "Create a note first."

    // MARK: Actions

    static let editNote = "Edit Note"
    static let showNote = "Show Note"
    static let openInEditor = "Open in Default Editor"
    static let copyMarkdown = "Copy as Markdown"
    static let copiedMarkdown = "Copied Markdown"
    static let copyPlainText = "Copy as Plain Text"
    static let copiedPlainText = "Copied Plain Text"
    static let pasteNote = "Paste Note"
    static let pinNote = "Pin Note"
    static let unpinNote = "Unpin Note"
    static let pinned = "Pinned Note"
    static let unpinned = "Unpinned Note"
    static let renameNote = "Rename Note"
    static let duplicateNote = "Duplicate Note"
    static let showInFinder = "Show in Finder"
    static let moveToTrash = "Move to Trash"
    static let movedToTrash = "Moved to Trash"
    static let trashMessage = "The file moves to the Trash, where you can put it back."
    static let openNote = "Open Note"
    static let editCopy = "Edit Copy"

    static func trashQuestion(_ title: String) -> String { "Move “\(title)” to the Trash?" }
    static func duplicated(_ title: String) -> String { "Duplicated “\(title)”" }
    static func renamed(_ title: String) -> String { "Renamed to “\(title)”" }

    // MARK: Forms

    static let editTitle = "Edit Note"
    static let renameTitle = "Rename Note"
    static let titleField = "Title"
    static let titlePlaceholder = "Title"
    static let titleInfo = "The note's first heading. The file is named after it."
    static let bodyField = "Text"
    static let bodyPlaceholder = "Write in Markdown"
    static let bodyInfo = "Kept as Markdown, exactly as you type it."
    static let tagsField = "Tags"
    static let tagsInfo = "Saved as #tags on the note's last line, which other Markdown editors read as tags too."
    static let createSubmit = "Create Note"
    static let saveSubmit = "Save Note"
    static let renameSubmit = "Rename Note"
    static let appendSubmit = "Append Text"
    static let appendField = "Text"
    static let appendPlaceholder = "Text to add at the end"
    static let needsText = "Type a title or some text."
    static let needsTitle = "Type a title."
    static let needsAppendText = "Type the text to add."
    static let badTags = "Tags take letters, digits, “-”, “_” and “/”, and not only digits."
    static let tooManyTags = "Use \(NoteText.maximumTags) tags at most."
    static let created = "Created Note"
    static let saved = "Saved Note"
    static let savedAsCopy = "Saved as a New Note"
    static let savedAsCopyMessage =
        "The note changed in another app while you edited it, so your version was saved beside it."

    static func appendTitle(_ title: String) -> String { "Append to “\(title)”" }
    static func appended(_ title: String) -> String { "Appended to “\(title)”" }

    // MARK: Quick capture

    static func captureTitle(_ text: String) -> String { "Create Note “\(text)”" }
    static let captureSubtitle = "Saves the text as a new Markdown note."
    static let saveCapture = "Save Note"
    static let editBeforeSaving = "Edit Before Saving"

    // MARK: Detail

    static let tagsLabel = "Tags"
    static let modifiedLabel = "Modified"
    static let wordsLabel = "Words"
    static let fileLabel = "File"
    static let pinnedTag = "Pinned"
    static let notDownloadedBody =
        "This note is in iCloud and not downloaded yet. Open it in your editor to download it."

    static func cutPreview(_ characters: Int, locale: Locale) -> String {
        let count = characters.formatted(IntegerFormatStyle<Int>.number.locale(locale))
        return "\n\n---\n\n*Showing the first \(count) characters. Open the note in your editor to see the rest.*"
    }

    static func unreadableBody(_ reason: String) -> String { "This note could not be read. \(reason)" }

    // MARK: Folder problems

    static func problemTitle(_ problem: FolderProblem) -> String {
        switch problem {
        case .missing: "Notes Folder Is Missing"
        case .notAFolder: "Notes Folder Is Not a Folder"
        case .refused, .failed: "Notes Folder Cannot Be Read"
        case .outsideRun: "Notes Folder Is Outside This Run"
        case .waitingForRead: "Notes Folder Not Read Yet"
        }
    }

    static func problemMessage(_ problem: FolderProblem, folder: NoteFolder) -> String {
        let name = "“" + DisplayText.fileName(folder.url.lastPathComponent) + "”"
        switch problem {
        case .missing:
            return "\(name) was moved or deleted. Choose it again in settings, or use the default folder."
        case .notAFolder:
            return "\(name) is not a folder. Choose a folder in settings, or use the default folder."
        case .refused:
            return "macOS refused access to \(name). Allow it in System Settings under Privacy & Security, "
                + "Files and Folders, or use the default folder."
        case .failed(let code):
            return "Reading \(name) failed: \(errorText(code)). Use the default folder, or choose the folder again."
        case .outsideRun:
            return "Scenarios, self-tests and benchmarks keep notes in their own temporary folder."
        case .waitingForRead:
            return "macOS may ask before \(name) is read. Press Read Folder to read it now."
        }
    }

    static let useDefaultFolder = "Use Default Folder"
    static let readFolder = "Read Folder"
    static let chooseFolder = "Choose Folder…"

    // MARK: Limits

    static let limitedTitle = "Some Notes Are Limited"

    static func limitsMessage(_ stats: ScanStats, limits: NoteLimits, locale: Locale) -> String {
        func number(_ value: Int) -> String { value.formatted(IntegerFormatStyle<Int>.number.locale(locale)) }
        func notes(_ count: Int) -> String { count == 1 ? "1 note" : number(count) + " notes" }
        var sentences: [String] = []
        if stats.leftOut > 0 {
            sentences.append(
                "Showing the \(number(limits.notes)) most recently changed notes. \(notes(stats.leftOut)) "
                    + "\(stats.leftOut == 1 ? "is" : "are") left out.")
        }
        if stats.cut > 0 {
            let size = bytes(limits.bytesPerNote)
            sentences.append(
                "\(notes(stats.cut)) \(stats.cut == 1 ? "is" : "are") longer than \(size). Search reads the first \(size)."
            )
        }
        if stats.titleOnly > 0 {
            sentences.append(
                "\(notes(stats.titleOnly)) \(stats.titleOnly == 1 ? "is" : "are") found by title only, because the "
                    + "text of all notes passes \(bytes(limits.searchBytes)).")
        }
        if stats.notDownloaded > 0 {
            let one = stats.notDownloaded == 1
            sentences.append(
                "\(notes(stats.notDownloaded)) \(one ? "is" : "are") in iCloud and not downloaded, so "
                    + "\(one ? "it is" : "they are") found by file name.")
        }
        if stats.notText > 0 {
            let files = stats.notText == 1 ? "1 file" : number(stats.notText) + " files"
            sentences.append("\(files) named like notes \(stats.notText == 1 ? "is" : "are") not text and left out.")
        }
        if stats.links > 0 {
            let links = stats.links == 1 ? "1 link" : number(stats.links) + " links"
            sentences.append(
                "\(links) \(stats.links == 1 ? "is" : "are") left out. Notes are never read through links.")
        }
        if stats.unreadable > 0 {
            sentences.append("\(notes(stats.unreadable)) could not be read.")
        }
        if stats.entriesCut {
            sentences.append(
                "The folder holds more than \(number(limits.entries)) items. Only the first \(number(limits.entries)) "
                    + "are looked at.")
        }
        return sentences.joined(separator: " ")
    }

    static func bytes(_ count: Int) -> String {
        if count >= 1 << 20, count % (1 << 20) == 0 { return "\(count >> 20) MB" }
        if count >= 1 << 10, count % (1 << 10) == 0 { return "\(count >> 10) KB" }
        return "\(count) bytes"
    }

    static func errorText(_ code: Int32) -> String {
        guard let text = strerror(code) else { return "error \(code)" }
        return String(cString: text).lowercased()
    }

    // MARK: Failures

    static let noteGone = ActionFailure("Note Not Found", message: "It was moved, renamed or deleted in another app.")
    static let tooLong = ActionFailure(
        "Note Too Long", message: "This note is too long to change here. Open it in your editor instead.")
    static let notText = ActionFailure("Not a Text File", message: "This file does not hold text.")
    static let notDownloaded = ActionFailure(
        "Note Not Downloaded", message: "Open it in your editor to download it from iCloud.")
    static let notPlainText = ActionFailure(
        "Note Uses Another Encoding",
        message: "Its file is not plain UTF-8 text, so changing it here could damage it. Open it in your editor "
            + "instead.")
    static let changedElsewhere = ActionFailure(
        "Note Changed in Another App", message: "Nothing was changed. Try again.")
    static let nameTaken = ActionFailure("Could Not Name the Note", message: "Every name tried is taken.")
    static let nothingToAppend = ActionFailure("Nothing to Append", message: "Type the text to add.")
    static let notALink = ActionFailure(
        "Not a Note", message: "It is a link, a folder or a special file, which the feature never opens.")
    static let writeRefused = ActionFailure(
        "Notes Folder Cannot Be Written", message: "macOS or the folder's permissions refused the change.")

    static func saveFailed(_ code: Int32) -> ActionFailure {
        ActionFailure("Could Not Save the Note", message: "Writing failed: \(errorText(code)).")
    }

    static func unavailable(_ problem: FolderProblem, folder: NoteFolder) -> ActionFailure {
        ActionFailure(problemTitle(problem), message: problemMessage(problem, folder: folder))
    }

    // MARK: Pins

    static let pinsUnreadableTitle = "Pins Could Not Be Read"
    static let pinsUnreadableMessage =
        "The file that keeps pins cannot be read, so pins cannot change. It is kept as it is."
    static let pinsNewerTitle = "Pins Are Read Only"
    static let pinsNewerMessage = "Pins were saved by a newer version, so they cannot change here."
    static let pinsFailed = ActionFailure("Could Not Save Pins", message: "The pin was not changed.")

    // MARK: Settings

    static let rootSection = "Root Search"
    static let rootToggle = "Show note titles in root search"
    static let rootToggleInfo =
        "Off by default, because titles can hold private words and root search shows them for unrelated "
        + "queries. Search Notes and quick capture work either way."
    static let folderSection = "Notes Folder"
    static let folderFooter =
        "Choosing a folder does not move notes: the old folder keeps them. A folder macOS guards, such as "
        + "Documents, asks for access the first time it is read, right after you choose it."
    static let defaultFolderNote = "Notes are kept in the feature's own data folder."
    static let chooseFolderDialog = "Choose a Folder for Notes"
    static let folderChanged = "Notes Folder Changed"
    static let folderChangedMessage = "Notes in the old folder stay there."
    static let usingDefaultFolder = "Using the Default Folder"
    static let captureSection = "Quick Capture"
    static let captureToggle = "Save notes from root search"
    static let captureNote =
        "Type “note”, a space and your text in root search, then press Return to save it as a note."

    static func folderNote(_ path: String) -> String {
        "Notes are kept in “\(DisplayText.oneLine(path))”."
    }
}

extension NoteFailure {
    /// What the host shows for the failure.
    nonisolated func actionFailure(folder: NoteFolder) -> ActionFailure {
        switch self {
        case .tooLong: Strings.tooLong
        case .notText: Strings.notText
        case .nothingToAppend: Strings.nothingToAppend
        case .unavailable(let problem): Strings.unavailable(problem, folder: folder)
        case .disk(let error):
            switch error {
            case .missing: Strings.noteGone
            case .folderMissing: Strings.unavailable(.missing, folder: folder)
            case .notRegularFile, .badName: Strings.notALink
            case .notDownloaded: Strings.notDownloaded
            case .changedElsewhere: Strings.changedElsewhere
            case .nameTaken: Strings.nameTaken
            case .accessRefused: Strings.writeRefused
            case .outsideRun: Strings.unavailable(.outsideRun, folder: folder)
            case .notAFolder: Strings.unavailable(.notAFolder, folder: folder)
            case .system(let code): Strings.saveFailed(code)
            }
        }
    }
}
