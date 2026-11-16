import CoreBridge
import Darwin
import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import FileSearch

/// A synthetic home folder under the system temporary folder, never the user's. Names are written
/// through POSIX calls byte for byte, and the folder that holds it is named with digits only, so its
/// own name matches no test query.
nonisolated final class TestTree: Sendable {
    private static let counter = Atomic<Int>(0)

    /// The fake storage's root: `home` and the feature's data folder live below it.
    let root: URL
    /// The home folder, as a real path.
    let home: String

    /// Files every test tree starts with, relative to home.
    static let files = [
        "notes.md", "report-2024.pdf", "beach.jpg", "Projects/app/src/main.swift", "Projects/app/README.md",
        "Projects/app/node_modules/pkg/index.js", "Projects/app/.git/config", ".hidden-config/secret.txt",
        "Library/Caches/cachefile.db", "Library/Mobile Documents/com~apple~CloudDocs/cloudnote.txt",
        "Desktop/desktop-shot.png", "Documents/letter.txt", "Downloads/installer.dmg", "Music/album/track.mp3",
        "Tool.app/Contents/Info.plist", "Gallery.photoslibrary/database/store.db", "Archive/old-photos.zip",
    ]

    init(files: [String] = TestTree.files) throws {
        let temporary = FileManager.default.temporaryDirectory.path
        let real = realpath(temporary, nil)
        defer { free(real) }
        let base = real.map { String(cString: $0) } ?? temporary
        let n = Self.counter.add(1, ordering: .relaxed).newValue
        root = URL(filePath: base + "/\(ProcessInfo.processInfo.processIdentifier)0\(n)", directoryHint: .isDirectory)
        home = root.path(percentEncoded: false).trimmingSuffix("/") + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        for file in files { try write(file) }
    }

    /// Writes a file of `size` bytes below home, making its folders.
    @discardableResult
    func write(_ relative: String, size: Int = 8) throws -> String {
        let full = path(relative)
        var built = home
        for part in relative.split(separator: "/").dropLast() {
            built += "/" + part
            _ = mkdir(built, 0o755)
        }
        let fd = open(full, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let bytes = [UInt8](repeating: 0x78, count: size)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == size else {
            throw CocoaError(.fileWriteUnknown)
        }
        return full
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? home : home + "/" + relative
    }

    func url(_ relative: String) -> URL {
        URL(filePath: path(relative))
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    /// Where the feature keeps its index file.
    var indexFile: String {
        root.path(percentEncoded: false).trimmingSuffix("/") + "/data/files/" + FileSearchFeature.indexFileName
    }

    deinit {
        // A test may have locked a folder; open it again so the whole tree can go.
        for folder in ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"] {
            _ = chmod(home + "/" + folder, 0o755)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

nonisolated extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}

/// The disk index maker, counting what it is asked to do, so tests can tell a walk from an event
/// and see every event path that reached the index.
nonisolated final class CountingMaker: IndexMaker {
    private struct Counts {
        var opens = 0
        var builds = 0
        var rebuilds = 0
        var saves = 0
        var stoppedWalks = 0
        var batches: [[FileEvent]] = []
        var savedMarks: [FileChangeMark?] = []
        var holdsBuild = false
        var heldBuildWaits = false
        var nextApplyError: CoreError?
        var buildStarted: CheckedContinuation<Void, Never>?
    }

    private let disk = DiskIndexMaker()
    private let counts = Mutex(Counts())

    var opens: Int { counts.withLock { $0.opens } }
    var builds: Int { counts.withLock { $0.builds } }
    var rebuilds: Int { counts.withLock { $0.rebuilds } }
    var saves: Int { counts.withLock { $0.saves } }
    /// Walks that a cancellation stopped.
    var stoppedWalks: Int { counts.withLock { $0.stoppedWalks } }
    var batches: [[FileEvent]] { counts.withLock { $0.batches } }
    /// The mark of every save, in order.
    var savedMarks: [FileChangeMark?] { counts.withLock { $0.savedMarks } }
    /// Every walk: opens that built, builds and rebuilds.
    var walks: Int { counts.withLock { $0.builds + $0.rebuilds } }

    /// Makes the next open or build wait, before it reads a folder, until its cancellation is
    /// cancelled. ``waitForHeldBuild()`` returns once it waits.
    func holdNextBuild() {
        counts.withLock { $0.holdsBuild = true }
    }

    /// Returns once a held build waits.
    @concurrent func waitForHeldBuild() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = counts.withLock { counts -> Bool in
                if counts.heldBuildWaits { return true }
                counts.buildStarted = continuation
                return false
            }
            if waits { continuation.resume() }
        }
    }

    /// A held build waits here until the flag the walk itself checks is set.
    private func holdIfAsked(_ cancellation: FileWalkCancellation?) {
        let (holds, waiter) = counts.withLock { counts -> (Bool, CheckedContinuation<Void, Never>?) in
            guard counts.holdsBuild else { return (false, nil) }
            counts.holdsBuild = false
            counts.heldBuildWaits = true
            defer { counts.buildStarted = nil }
            return (true, counts.buildStarted)
        }
        guard holds else { return }
        waiter?.resume()
        while cancellation?.isCancelled == false {
            usleep(200)
        }
    }

    private func counting<T>(_ walk: () throws -> T) throws -> T {
        do {
            return try walk()
        } catch CoreError.cancelled {
            counts.withLock { $0.stoppedWalks += 1 }
            throw CoreError.cancelled
        }
    }

    func open(
        at file: String, _ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?
    ) throws -> (FileIndex, IndexOpening) {
        holdIfAsked(cancellation)
        let result = try counting { try disk.open(at: file, configuration, cancellation: cancellation) }
        counts.withLock { counts in
            counts.opens += 1
            if !result.1.fromFile { counts.builds += 1 }
        }
        return result
    }

    func build(_ configuration: FileIndexConfiguration, cancellation: FileWalkCancellation?) throws -> FileIndex {
        holdIfAsked(cancellation)
        counts.withLock { $0.builds += 1 }
        return try counting { try disk.build(configuration, cancellation: cancellation) }
    }

    func rebuild(_ index: FileIndex, cancellation: FileWalkCancellation?) throws {
        counts.withLock { $0.rebuilds += 1 }
        try counting { try disk.rebuild(index, cancellation: cancellation) }
    }

    func apply(_ events: [FileEvent], to index: FileIndex, cancellation: FileWalkCancellation?) throws -> Bool {
        let failure = counts.withLock { counts -> CoreError? in
            counts.batches.append(events)
            defer { counts.nextApplyError = nil }
            return counts.nextApplyError
        }
        if let failure { throw failure }
        return try disk.apply(events, to: index, cancellation: cancellation)
    }

    /// Makes the next batch of events fail with `error` without touching the index.
    func failNextApply(with error: CoreError) {
        counts.withLock { $0.nextApplyError = error }
    }

    func save(_ index: FileIndex, to file: String, mark: FileChangeMark?) throws {
        counts.withLock { counts in
            counts.saves += 1
            counts.savedMarks.append(mark)
        }
        try disk.save(index, to: file, mark: mark)
    }

    func savedMark(for file: String) -> FileChangeMark? {
        disk.savedMark(for: file)
    }
}

/// A file system that records which paths had their facts read, lists the volumes it is given and
/// lists the test's own folders through the feature's guard, with any device allowed.
nonisolated final class RecordingFileSystem: FileSystem {
    private struct State {
        var volumes = MountedVolumes()
        var factsRead: [String] = []
        var volumeReads = 0
        var listed: [String] = []
        var refused: [String] = []
    }

    private let state = Mutex(State())

    var volumes: MountedVolumes {
        get { state.withLock { $0.volumes } }
        set { state.withLock { $0.volumes = newValue } }
    }

    var factsRead: [String] { state.withLock { $0.factsRead } }
    var volumeReads: Int { state.withLock { $0.volumeReads } }
    /// Folders listed from disk, and folders the guard refused, as asked.
    var listed: [String] { state.withLock { $0.listed } }
    var refused: [String] { state.withLock { $0.refused } }

    @concurrent func mountedVolumes() async -> MountedVolumes {
        state.withLock { state in
            state.volumeReads += 1
            return state.volumes
        }
    }

    @concurrent func listFolder(_ folder: String, scope: ScopePlan) async -> FolderListing? {
        let browseGuard = BrowseGuard(refused: [scope.home] + scope.blocked, devices: nil)
        guard let path = browseGuard.listablePath(folder) else {
            state.withLock { $0.refused.append(folder) }
            return nil
        }
        state.withLock { $0.listed.append(folder) }
        return try? FileIndex.listFolder(path, rules: scope.configuration)
    }

    @concurrent func facts(of path: String) async -> FileFacts? {
        state.withLock { $0.factsRead.append(path) }
        return FileFacts(
            kind: "Test kind", created: Date(timeIntervalSince1970: 1_790_000_000),
            modified: Date(timeIntervalSince1970: 1_791_000_000), size: 8)
    }
}

/// A feature over a test tree, with the disk index maker pointed at it and every permission
/// unanswered unless the test says otherwise.
@MainActor
struct Fixture {
    let tree: TestTree
    let maker = CountingMaker()
    let fileSystem = RecordingFileSystem()
    let harness: FeatureHarness<FileSearchFeature>

    init(
        tree: TestTree? = nil, permissions: PermissionStatus = .notDetermined,
        granted: [Permission] = [], settings: (FeatureSettings) -> Void = { _ in }
    ) throws {
        let tree = try tree ?? TestTree()
        self.tree = tree
        let fakes = FakeServices(permissions: permissions, storageRoot: tree.root)
        for permission in granted { fakes.permissions.set(permission, to: .granted) }
        fakes.override(IndexMakerKey.self, with: maker)
        fakes.override(FileSystemKey.self, with: fileSystem)
        settings(fakes.context(featureID: FileSearchFeature.manifest.id).settings)
        harness = FeatureHarness(FileSearchFeature.self, fakes: fakes)
    }

    var feature: FileSearchFeature { harness.feature }
    var fakes: FakeServices { harness.fakes }

    /// Activates and waits for the first open and anything it started.
    func start() async throws {
        await harness.activate()
        try await idle()
    }

    /// Waits until the fakes' streams, the feature's scope changes and the index queue are all
    /// quiet, in rounds, because each may start work in the others.
    func idle() async throws {
        for _ in 0..<4 {
            try await harness.settle()
            await feature.waitUntilIdle()
        }
    }

    /// Titles of the root search rows for a query.
    func rootTitles(_ query: String) async throws -> [String] {
        try await harness.asyncSections(for: query).flatMap(\.rows).map(\.title)
    }

    /// The paths, relative to home, of every root search row for a query.
    func rootPaths(_ query: String) async throws -> [String] {
        try await harness.asyncSections(for: query).flatMap(\.rows).map { relative($0.id.key) }
    }

    func relative(_ path: String) -> String {
        path == tree.home ? "" : String(path.dropFirst(tree.home.count + 1))
    }

    /// Every event path that reached the index, relative to home.
    var appliedPaths: [String] {
        maker.batches.flatMap { $0.map { relative($0.path) } }
    }

    /// A row for a path, as root search would rebuild it from a snapshot without a payload.
    func bareRow(_ relative: String) -> Row {
        Row(id: ItemID(FileRows.namespace, tree.path(relative)), title: Paths.name(of: tree.path(relative)))
    }
}
