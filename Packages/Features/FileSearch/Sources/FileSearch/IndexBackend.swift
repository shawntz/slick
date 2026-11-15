import CoreBridge
import Foundation
import Kit

/// Makes and changes the file index. Every requirement blocks while it reads or writes the disk, so
/// the feature calls them only on its index queue, never on the main thread.
///
/// The disk maker walks exactly the roots its configuration names and writes only the index file
/// it is given, so tests point it at temporary trees. The synthetic maker reads and writes nothing.
nonisolated protocol IndexMaker: Sendable {
    /// Opens the index file at `file` when it was saved for the same configuration, and walks the
    /// roots otherwise.
    func open(at file: String, _ configuration: FileIndexConfiguration) throws -> (FileIndex, IndexOpening)

    /// Walks the roots into a new index.
    func build(_ configuration: FileIndexConfiguration) throws -> FileIndex

    /// Walks every root of `index` again and publishes the result.
    func rebuild(_ index: FileIndex) throws

    /// Applies one batch of events. True when the index published a new snapshot.
    func apply(_ events: [FileEvent], to index: FileIndex) throws -> Bool

    /// Writes the index to `file` atomically, creating its folder.
    func save(_ index: FileIndex, to file: String) throws
}

/// What opening the index did.
nonisolated struct IndexOpening: Hashable, Sendable {
    /// True when the index came from the saved file.
    var fromFile: Bool
    /// Why the saved file was not used, when it was not.
    var loadError: FileIndexLoadError?

    /// True when the saved file was damaged and the index was walked again.
    var wasDamaged: Bool { loadError == .corrupt }
}

/// What the feature needs from the Mac beyond Kit's services and the index itself.
nonisolated protocol FileSystem: Sendable {
    /// Mounted removable and network volumes. Reads volume metadata only, never what a volume
    /// holds. Called only after the user chose to search a kind of volume.
    @concurrent func mountedVolumes() async -> MountedVolumes

    /// The names in one folder, or nil when it cannot be listed. Called only for the home folder's
    /// Library and its Mobile Documents folder, and only while iCloud Drive is searched.
    @concurrent func names(in folder: String) async -> [String]?

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
    func open(at file: String, _ configuration: FileIndexConfiguration) throws -> (FileIndex, IndexOpening) {
        let (index, info) = try FileIndex.openOrBuild(at: file, configuration)
        return (index, IndexOpening(fromFile: info.opened, loadError: info.loadError))
    }

    func build(_ configuration: FileIndexConfiguration) throws -> FileIndex {
        try FileIndex.build(configuration).index
    }

    func rebuild(_ index: FileIndex) throws {
        try index.rebuild()
    }

    func apply(_ events: [FileEvent], to index: FileIndex) throws -> Bool {
        try index.apply(events).published
    }

    /// The event ID is 0: Kit's file watcher gives no FSEvents IDs, so the feature walks again
    /// after opening a saved index instead of resuming the event stream.
    func save(_ index: FileIndex, to file: String) throws {
        try FileManager.default.createDirectory(atPath: Paths.parent(of: file), withIntermediateDirectories: true)
        try index.save(to: file, eventID: 0)
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

    func open(at file: String, _ configuration: FileIndexConfiguration) throws -> (FileIndex, IndexOpening) {
        (try build(configuration), IndexOpening(fromFile: false, loadError: nil))
    }

    func build(_ configuration: FileIndexConfiguration) throws -> FileIndex {
        try FileIndex.synthetic(root: root, entries: entries, seed: seed)
    }

    func rebuild(_ index: FileIndex) throws {}

    func apply(_ events: [FileEvent], to index: FileIndex) throws -> Bool { false }

    func save(_ index: FileIndex, to file: String) throws {}
}

/// Volumes and file facts for scenarios, self-tests and benchmarks: no volumes, and a kind taken
/// from the name alone. Reads nothing.
nonisolated struct SimulatedFileSystem: FileSystem {
    @concurrent func mountedVolumes() async -> MountedVolumes { MountedVolumes() }

    @concurrent func names(in folder: String) async -> [String]? { nil }

    @concurrent func facts(of path: String) async -> FileFacts? {
        FileFacts(
            kind: FileKind.of(name: Paths.name(of: path), isFolder: false, isPackage: false).map(Strings.Kinds.singular)
        )
    }
}
