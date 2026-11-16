import Foundation
import Kit

/// Where notes live now.
nonisolated struct NoteFolder: Hashable, Sendable {
    var url: URL
    /// True for the folder in the feature's own data folder.
    var isDefault: Bool
    /// The guarded place that holds the folder, if any.
    var guarded: GuardedPlace?

    var path: String { PosixNoteDisk.comparablePath(url) }

    /// The key pins are kept under, so the default folder keeps its pins when the data folder moves.
    var pinKey: String { isDefault ? "default" : path }

    /// The name of the default folder inside the feature's data folder.
    static let defaultName = "Notes"
}

/// The text of a note held for search: as written, and folded for matching.
nonisolated struct NoteSearchText: Sendable {
    let original: String
    let folded: String

    init(_ original: String) {
        self.original = original
        folded = NoteSearch.fold(original)
    }

    var bytes: Int { original.utf8.count }
}

/// One note as the last scan read it. Built off the main thread and never changed.
nonisolated struct NoteRecord: Sendable {
    let fileName: String
    /// The title to show: one line, inline marks dropped, never empty.
    let title: String
    let foldedTitle: String
    let tags: [String]
    /// The first line of the body, to show under the title.
    let preview: String
    let modified: Date
    let version: FileVersion
    /// True when the note is longer than the feature reads.
    let isCut: Bool
    /// True when the note's contents are only in the cloud, so it was not read.
    let isDataless: Bool
    /// The text search reads, or nil past the search budget or for a note not downloaded.
    let text: NoteSearchText?
    /// True when the text was left out because the search budget ran out.
    let isTitleOnly: Bool

    /// The same note without its search text.
    func titleOnly() -> NoteRecord {
        NoteRecord(
            fileName: fileName, title: title, foldedTitle: foldedTitle, tags: tags, preview: preview,
            modified: modified, version: version, isCut: isCut, isDataless: isDataless, text: nil, isTitleOnly: true)
    }
}

/// What a scan found that the user should know.
nonisolated struct ScanStats: Hashable, Sendable {
    /// Notes past the note cap, the oldest ones.
    var leftOut = 0
    /// Notes longer than the part search reads.
    var cut = 0
    /// Files named like notes that are not text: binary data, pipes, devices.
    var notText = 0
    /// Symbolic links named like notes, which the feature never follows.
    var links = 0
    /// Notes found by title only, past the search budget.
    var titleOnly = 0
    /// Notes whose contents are only in the cloud.
    var notDownloaded = 0
    /// Notes that could not be read, such as one whose permissions refuse it.
    var unreadable = 0
    /// True when the folder holds more entries than one scan looks at.
    var entriesCut = false

    var isQuiet: Bool { self == ScanStats() }
}

/// Why the folder shows no notes.
nonisolated enum FolderProblem: Hashable, Sendable {
    /// The folder the user chose is gone.
    case missing
    case notAFolder
    /// macOS or the folder's permissions refused the read.
    case refused
    /// The run keeps notes in its own temporary folders.
    case outsideRun
    /// Any other failure, by `errno`.
    case failed(Int32)
    /// A guarded folder that has not been read since the user chose it. Reading it may make macOS
    /// ask, so it waits for the user to press Read Folder.
    case waitingForRead
}

/// Every note the feature lists, newest first, with what the scan found. A value, so the main
/// thread reads it without waiting.
nonisolated struct NoteIndex: Sendable {
    let folder: NoteFolder
    let notes: [NoteRecord]
    let stats: ScanStats
    let problem: FolderProblem?
    /// Every tag, sorted without case.
    let tags: [String]
    /// Counts up with every scan and change, so an older result is never applied over a newer one.
    let generation: Int
    /// Tells two indexes apart without comparing text: names, versions, what search holds, the
    /// counts and the problem. Made with the index, off the main thread.
    let fingerprint: Int
    private let positions: [String: Int]

    init(
        folder: NoteFolder, notes: [NoteRecord] = [], stats: ScanStats = ScanStats(), problem: FolderProblem? = nil,
        generation: Int
    ) {
        self.folder = folder
        self.generation = generation
        self.notes = notes
        self.stats = stats
        self.problem = problem
        var positions: [String: Int] = [:]
        var tags: [String: String] = [:]
        for (index, note) in notes.enumerated() {
            positions[note.fileName] = index
            for tag in note.tags { tags[tag.lowercased()] = tags[tag.lowercased()] ?? tag }
        }
        self.positions = positions
        self.tags = tags.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var hasher = Hasher()
        hasher.combine(folder)
        hasher.combine(stats)
        hasher.combine(problem)
        for note in notes {
            hasher.combine(note.fileName)
            hasher.combine(note.version)
            hasher.combine(note.text == nil)
        }
        fingerprint = hasher.finalize()
    }

    func note(named fileName: String) -> NoteRecord? {
        positions[fileName].map { notes[$0] }
    }

    /// The note's file.
    func url(of fileName: String) -> URL {
        folder.url.appending(path: fileName, directoryHint: .notDirectory)
    }
}
