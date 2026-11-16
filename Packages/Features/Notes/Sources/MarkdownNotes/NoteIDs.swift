import Foundation
import Kit

/// The feature's IDs, namespaces and keys, in one place.
nonisolated enum NoteIDs {
    static let feature = "notes"
    /// Rows that stand for a note: `notes:<file name>`. The file name is the key, so a row keeps its
    /// identity until the note is renamed.
    static let namespace = "notes"
    /// The quick capture row in root search.
    static let captureNamespace = "notes.capture"

    static let searchCommand = "search"
    static let createCommand = "create"
    static let appendCommand = "append"

    /// The argument of Append to Note, and the undeclared argument Create Note takes from code.
    static let textArgument = "text"

    /// The word that starts quick capture in root search, followed by a space and the text.
    static let captureKeyword = "note"

    static func command(_ id: String) -> ItemID {
        .command(feature: feature, command: id)
    }

    /// The row ID of the note in this file.
    static func row(_ fileName: String) -> ItemID {
        ItemID(namespace, fileName)
    }

    /// The file name a row stands for, when it is one of this feature's note rows and its key is a
    /// note's file name. A crafted key, such as one that climbs out of the folder, gives nil.
    static func fileName(of row: Row) -> String? {
        guard row.id.namespace == namespace else { return nil }
        let key = row.id.key
        return NoteFileName.isNoteFile(key) ? key : nil
    }
}

/// The caps that keep the feature fast whatever the folder holds. Past each one the feature says so
/// and keeps working.
nonisolated struct NoteLimits: Hashable, Sendable {
    /// The most notes the feature lists. The most recently changed ones are kept.
    var notes = 5_000
    /// The most bytes of one note read for search and titles.
    var bytesPerNote = 1 << 20
    /// The most bytes of note text held in memory for search, across every note. Newer notes come
    /// first; older ones past this are found by their titles only.
    var searchBytes = 64 << 20
    /// The most folder entries looked at in one scan, so a folder with a million files costs a
    /// bounded amount.
    var entries = 50_000
    /// The most bytes read for an action that needs the whole note, such as Copy as Markdown.
    var bytesForActions = 16 << 20
    /// The most characters the detail pane shows.
    var previewCharacters = 20_000

    static let standard = NoteLimits()
}
