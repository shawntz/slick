import CoreBridge
import Foundation
import Kit

/// Makes and changes the file index. Every requirement blocks while it reads or writes the disk, so
/// the feature calls them only on its index queue, never on the main thread.
///
/// A walk stops at its next folder once `cancellation` is cancelled, and throws
/// `CoreError.cancelled`; it publishes nothing then. A nil flag never stops.
///
/// The disk maker walks exactly the roots its configuration names and writes only the index file
/// and its mark file, so tests point it at temporary trees. The synthetic maker reads and writes
/// nothing.
nonisolated protocol IndexMaker: Sendable {
    /// Opens the index file at `file` when it was saved for the same configuration, and walks the
    /// roots otherwise.
    func open(
        at file: String, _ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?
    ) throws -> (FileIndex, IndexOpening)

    /// Walks the roots into a new index.
    func build(_ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?) throws -> FileIndex

    /// Walks every root of `index` again and publishes the result.
    func rebuild(_ index: FileIndex, cancellation: FileWalkCancellation?) throws

    /// Applies one batch of events. True when the index published a new snapshot.
    func apply(_ events: [FileEvent], to index: FileIndex, cancellation: FileWalkCancellation?) throws -> Bool

    /// Writes the index to `file` atomically, creating its folder, and the mark the index is current
    /// to beside it. Without a mark, the mark file is removed, so the next start walks again.
    func save(_ index: FileIndex, to file: String, mark: FileChangeMark?) throws

    /// The mark saved beside the index file, or nil when there is none or it cannot be read.
    func savedMark(for file: String) -> FileChangeMark?
}

/// What opening the index did.
nonisolated struct IndexOpening: Hashable, Sendable {
    /// True when the index came from the saved file.
    var fromFile: Bool
    /// Why the saved file was not used, when it was not.
    var loadError: FileIndexLoadError?
    /// The event ID the saved file is current to, 0 when it was built or saved without one.
    var eventID: UInt64 = 0

    /// True when the saved file was damaged and the index was walked again.
    var wasDamaged: Bool { loadError == .corrupt }
}

/// What the feature needs from the Mac beyond Kit's services and the index itself.
nonisolated protocol FileSystem: Sendable {
    /// Mounted removable and network volumes. Reads volume metadata only, never what a volume
    /// holds. Called only after the user chose to search a kind of volume.
    @concurrent func mountedVolumes() async -> MountedVolumes

    /// The children of a folder the index does not hold, read from disk with the scope's rules, when
    /// ``BrowseGuard`` allows listing it. Nil when it does not, or when the folder cannot be listed.
    /// Called only for a folder the user typed.
    @concurrent func listFolder(_ folder: String, scope: ScopePlan) async -> FolderListing?

    /// The kind and dates of one file or folder. Reads its metadata only, never its contents.
    /// Called for the selected row of the Search Files page, and only for paths the scope allows.
    @concurrent func facts(of path: String) async -> FileFacts?
}

/// What the detail pane shows about one file, beyond what the index holds.
nonisolated struct FileFacts: Hashable, Sendable {
    /// The kind Finder shows, such as "PDF document".
    var kind: String?
    var created: Date?
    var modified: Date?
    var size: Int64?

    init(kind: String? = nil, created: Date? = nil, modified: Date? = nil, size: Int64? = nil) {
        self.kind = kind
        self.created = created
        self.modified = modified
        self.size = size
    }
}

/// The index maker for each kind of run. The app walks the real folders the scope names.
/// Scenarios, self-tests and benchmarks get a synthetic index below the run's synthetic home, so
/// they never show the user's files. Tests pass a ``DiskIndexMaker`` and point it at trees of their
/// own.
nonisolated enum IndexMakerKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any IndexMaker { DiskIndexMaker() }

    static func isolated(_ context: FeatureContext) -> any IndexMaker {
        SyntheticIndexMaker(
            root: Paths.normalized(context.storage.homeDirectory.path(percentEncoded: false), home: nil)
                ?? "/synthetic",
            entries: SyntheticIndexMaker.scenarioEntries)
    }
}

/// The file system service for each kind of run.
nonisolated enum FileSystemKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any FileSystem { LiveFileSystem() }
    static func isolated(_ context: FeatureContext) -> any FileSystem { SimulatedFileSystem() }
}

/// The index on disk, through the Rust core.
nonisolated struct DiskIndexMaker: IndexMaker {
    func open(
        at file: String, _ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?
    ) throws -> (FileIndex, IndexOpening) {
        let (index, info) =
            if let cancellation {
                try FileIndex.openOrBuild(at: file, configuration, cancellation: cancellation)
            } else {
                try FileIndex.openOrBuild(at: file, configuration)
            }
        return (index, IndexOpening(fromFile: info.opened, loadError: info.loadError, eventID: info.eventID))
    }

    func build(_ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?) throws -> FileIndex {
        if let cancellation { return try FileIndex.build(configuration, cancellation: cancellation).index }
        return try FileIndex.build(configuration).index
    }

    func rebuild(_ index: FileIndex, cancellation: FileWalkCancellation?) throws {
        if let cancellation {
            try index.rebuild(cancellation: cancellation)
        } else {
            try index.rebuild()
        }
    }

    func apply(_ events: [FileEvent], to index: FileIndex, cancellation: FileWalkCancellation?) throws -> Bool {
        if let cancellation { return try index.apply(events, cancellation: cancellation).published }
        return try index.apply(events).published
    }

    /// The mark file goes first, so a save cut short leaves no mark and the next start walks again
    /// rather than trust a mark the index does not match.
    func save(_ index: FileIndex, to file: String, mark: FileChangeMark?) throws {
        try FileManager.default.createDirectory(atPath: Paths.parent(of: file), withIntermediateDirectories: true)
        let markFile = Self.markFile(for: file)
        if FileManager.default.fileExists(atPath: markFile) { try FileManager.default.removeItem(atPath: markFile) }
        try index.save(to: file, eventID: mark?.eventID ?? 0)
        guard let mark else { return }
        try JSONEncoder().encode(mark).write(to: URL(filePath: markFile), options: [.atomic])
    }

    func savedMark(for file: String) -> FileChangeMark? {
        guard let data = FileManager.default.contents(atPath: Self.markFile(for: file)) else { return nil }
        return try? JSONDecoder().decode(FileChangeMark.self, from: data)
    }

    /// Where the mark of the index file at `file` is kept.
    static func markFile(for file: String) -> String {
        file + ".mark.json"
    }
}

/// A deterministic index of generic names built in memory, for scenarios, self-tests and
/// benchmarks. It reads and writes nothing: walking again and events change nothing, and saving
/// keeps nothing.
nonisolated struct SyntheticIndexMaker: IndexMaker {
    /// Entries in the index scenarios search.
    static let scenarioEntries = 3_000

    let root: String
    let entries: Int
    var seed: UInt64 = 7

    func open(
        at file: String, _ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?
    ) throws -> (FileIndex, IndexOpening) {
        (try build(configuration, cancellation: cancellation), IndexOpening(fromFile: false, loadError: nil))
    }

    func build(_ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?) throws -> FileIndex {
        try FileIndex.synthetic(root: root, entries: entries, seed: seed)
    }

    func rebuild(_ index: FileIndex, cancellation: FileWalkCancellation?) throws {}

    func apply(_ events: [FileEvent], to index: FileIndex, cancellation: FileWalkCancellation?) throws -> Bool {
        false
    }

    func save(_ index: FileIndex, to file: String, mark: FileChangeMark?) throws {}

    func savedMark(for file: String) -> FileChangeMark? { nil }
}

/// Volumes, folders and file facts for scenarios, self-tests and benchmarks: no volumes, no folder
/// outside the index, and a kind taken from the name alone. Reads nothing.
nonisolated struct SimulatedFileSystem: FileSystem {
    @concurrent func mountedVolumes() async -> MountedVolumes { MountedVolumes() }

    @concurrent func listFolder(_ folder: String, scope: ScopePlan) async -> FolderListing? { nil }

    @concurrent func facts(of path: String) async -> FileFacts? {
        FileFacts(
            kind: FileKind.of(name: Paths.name(of: path), isFolder: false, isPackage: false).map(Strings.Kinds.singular)
        )
    }
}
