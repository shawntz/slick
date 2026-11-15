import SlickCoreC

/// The launcher's own index of file names: a walker, a compact store, updates from FSEvents and
/// path-aware search in well under a millisecond.
///
/// Safe to use from any thread at once, and checked `Sendable` like `Engine`: searches read an
/// immutable snapshot and never wait for the writer, and one writer at a time applies events,
/// rebuilds or saves. Building, opening, applying events, rebuilding and saving read or write the
/// disk, so call them off the main thread. Search with a `FileSearchSession`.
public final class FileIndex: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        slick_files_free(handle)
    }

    /// Walks the roots of `configuration` into a new index.
    public static func build(_ configuration: FileIndexConfiguration) throws(CoreError) -> (
        index: FileIndex, walk: FileWalkStats
    ) {
        try RustCore.checkABI()
        var stats = SlickFilesWalkStats()
        var created: OpaquePointer?
        let status = configuration.withRaw { config, strings, count in
            slick_files_build(config, strings, count, &created, &stats)
        }
        try CoreError.check(status)
        guard let created else { throw .nullPointer }
        return (FileIndex(handle: created), FileWalkStats(stats))
    }

    /// Opens the index file at `path` when it was saved for the same roots and rules, and builds a
    /// new index otherwise. `info` says which happened and why.
    public static func openOrBuild(at path: String, _ configuration: FileIndexConfiguration) throws(CoreError) -> (
        index: FileIndex, info: FileIndexOpenInfo
    ) {
        try RustCore.checkABI()
        var info = SlickFilesOpenInfo()
        var created: OpaquePointer?
        var path = path
        let status = path.withUTF8 { file in
            configuration.withRaw { config, strings, count in
                slick_files_open_or_build(file.baseAddress, file.count, config, strings, count, &created, &info)
            }
        }
        try CoreError.check(status)
        guard let created else { throw .nullPointer }
        return (FileIndex(handle: created), FileIndexOpenInfo(info))
    }

    /// An index of about `entries` synthetic entries below the absolute path `root`, built in
    /// memory and deterministic for each `seed`. For tests and benchmarks.
    public static func synthetic(root: String, entries: Int, seed: UInt64) throws(CoreError) -> FileIndex {
        try RustCore.checkABI()
        var root = root
        var created: OpaquePointer?
        let n = UInt32(clamping: entries)
        try CoreError.check(root.withUTF8 { slick_files_synthetic($0.baseAddress, $0.count, n, seed, &created) })
        guard let created else { throw .nullPointer }
        return FileIndex(handle: created)
    }

    /// Live entries in the current snapshot.
    public func count() throws(CoreError) -> Int {
        Int(try CoreError.check(slick_files_count(handle)))
    }

    /// Applies one batch of FSEvents events: rescans only the folders they touch and publishes a
    /// new snapshot when anything changed. Searches keep running meanwhile. Call it from one queue.
    @discardableResult
    public func apply(_ events: [FileEvent]) throws(CoreError) -> FileUpdateStats {
        var paths: [UInt8] = []
        var raw: [SlickFilesEvent] = []
        raw.reserveCapacity(events.count)
        for event in events {
            let start = paths.count
            paths.append(contentsOf: event.path.utf8)
            guard let s = UInt32(exactly: start), let n = UInt32(exactly: paths.count - start) else {
                throw .invalidArgument
            }
            raw.append(SlickFilesEvent(path_start: s, path_len: n, flags: event.flags, reserved: 0))
        }
        var stats = SlickFilesUpdateStats()
        let status = raw.withUnsafeBufferPointer { e in
            paths.withUnsafeBufferPointer { p in
                slick_files_apply(handle, e.baseAddress, e.count, p.baseAddress, p.count, &stats)
            }
        }
        try CoreError.check(status)
        return FileUpdateStats(stats)
    }

    /// Walks every root again and publishes the result.
    @discardableResult
    public func rebuild() throws(CoreError) -> FileWalkStats {
        var stats = SlickFilesWalkStats()
        try CoreError.check(slick_files_rebuild(handle, &stats))
        return FileWalkStats(stats)
    }

    /// Writes the current snapshot to `path` atomically, with mode 0600. `eventID` is the FSEvents
    /// id the snapshot is current to; `openOrBuild` hands it back. Throws `.io` when the file
    /// cannot be written.
    public func save(to path: String, eventID: UInt64) throws(CoreError) {
        var path = path
        try CoreError.check(path.withUTF8 { slick_files_save(handle, $0.baseAddress, $0.count, eventID) })
    }

    /// The current snapshot. Cheap: one reference count.
    public func snapshot() throws(CoreError) -> FileSnapshot {
        var created: OpaquePointer?
        try CoreError.check(slick_files_snapshot(handle, &created))
        guard let created else { throw .nullPointer }
        return FileSnapshot(handle: created)
    }
}

/// An immutable view of a file index. Entry ids belong to one snapshot: keep the snapshot of a
/// result list to resolve its hits after the index changes.
public final class FileSnapshot: Sendable {
    nonisolated(unsafe) let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        slick_files_snapshot_free(handle)
    }

    /// Counts and memory.
    public var info: FileSnapshotInfo {
        var raw = SlickFilesInfo()
        slick_files_snapshot_info(handle, &raw)
        return FileSnapshotInfo(raw)
    }

    /// The absolute path of `id`, or nil when the snapshot does not hold it.
    public func path(of id: FileEntryID) -> String? {
        FilePaths.string { slick_files_snapshot_path(handle, id.rawValue, $0, $1) }
    }

    /// Facts about `id`, or nil when the snapshot does not hold it.
    public func entry(_ id: FileEntryID) -> FileEntry? {
        var raw = SlickFileEntry()
        guard slick_files_snapshot_entry(handle, id.rawValue, &raw) == 0 else { return nil }
        return FileEntry(raw)
    }

    /// The entry for an absolute path, or nil when the snapshot does not hold the whole path.
    public func lookup(path: String) -> FileEntryID? {
        var path = path
        var id = UInt32.max
        let found = path.withUTF8 { slick_files_snapshot_lookup(handle, $0.baseAddress, $0.count, &id) }
        return found == 1 ? FileEntryID(rawValue: id) : nil
    }
}

/// One search field's state: the searcher that narrows as the query grows, the hits of the last
/// search and the snapshot they belong to. Make one per field and call `reset()` when the panel
/// opens. After the first few searches the Swift side allocates nothing per search.
///
/// Not `Sendable`: a session belongs to whoever runs its searches, normally one worker queue.
public final class FileSearchSession {
    /// The most hits one search returns.
    public let capacity: Int
    /// Hits of the last search.
    public private(set) var count = 0
    let session: OpaquePointer
    private let hits: UnsafeMutableBufferPointer<SlickFileHit>
    private let ranges: UnsafeMutableBufferPointer<SlickRange>
    private let scratch: UnsafeMutableBufferPointer<UInt8>
    private var pathBuffer: UnsafeMutableBufferPointer<UInt8>

    /// A session for at most `capacity` hits.
    public init(capacity: Int = 50) throws(CoreError) {
        try RustCore.checkABI()
        var created: OpaquePointer?
        try CoreError.check(slick_files_session_new(&created))
        guard let created else { throw .nullPointer }
        session = created
        self.capacity = max(capacity, 1)
        hits = .allocate(capacity: self.capacity)
        hits.initialize(repeating: SlickFileHit())
        ranges = .allocate(capacity: 64)
        ranges.initialize(repeating: SlickRange())
        scratch = .allocate(capacity: 1024)
        scratch.initialize(repeating: 0)
        pathBuffer = .allocate(capacity: 1024)
        pathBuffer.initialize(repeating: 0)
    }

    deinit {
        slick_files_session_free(session)
        hits.deallocate()
        ranges.deallocate()
        scratch.deallocate()
        pathBuffer.deallocate()
    }

    /// The hit at `index`, best first.
    public subscript(index: Int) -> FileHit {
        precondition(index >= 0 && index < count, "hit index out of range")
        return FileHit(hits[index])
    }

    /// Forgets earlier queries, so the next search scans everything. The last hits stay readable.
    public func reset() {
        slick_files_session_reset(session)
    }

    /// Sets the folder a leading `~` expands to in folder queries. Nil turns `~` off.
    public func setHome(_ home: String?) {
        var home = home ?? ""
        home.withUTF8 { _ = slick_files_session_set_home(session, $0.baseAddress, $0.count) }
    }

    /// Searches the index's current snapshot for `text` and returns the number of hits. When the
    /// query only grew since the last search, only the previous matches are scored again. Text
    /// that starts with `/` or `~` lists a folder. Parts run in parallel inside Rust unless the
    /// options say otherwise. The Swift side allocates nothing, including the String to UTF-8 step.
    @discardableResult
    public func search(_ text: String, in index: FileIndex, options: FileSearchOptions = FileSearchOptions())
        throws(CoreError) -> Int
    {
        var raw = options.raw
        let status = withUTF8(of: text) { q, n in
            slick_files_search(index.handle, session, q, n, &raw, hits.baseAddress, capacity)
        }
        count = Int(try CoreError.check(status))
        return count
    }

    /// What the last search did.
    public var stats: FileSearchStats {
        var raw = SlickFilesSearchStats()
        slick_files_session_stats(session, &raw)
        return FileSearchStats(raw)
    }

    /// The absolute path of `id` in the last search's snapshot, or nil when it holds no such entry.
    public func path(of id: FileEntryID) -> String? {
        withPath(of: id) { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs `body` with the UTF-8 bytes of `id`'s absolute path, read into a buffer the session
    /// keeps. Nil when the last search's snapshot holds no such entry. Allocates nothing once the
    /// buffer fits the longest path.
    public func withPath<R>(of id: FileEntryID, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        var n = slick_files_session_path(session, id.rawValue, pathBuffer.baseAddress, pathBuffer.count)
        if n == SLICK_STATUS_BUFFER_TOO_SMALL.rawValue {
            let needed = Int(slick_files_session_path(session, id.rawValue, nil, 0))
            guard needed > 0 else { return nil }
            pathBuffer.deallocate()
            pathBuffer = .allocate(capacity: needed * 2)
            pathBuffer.initialize(repeating: 0)
            n = slick_files_session_path(session, id.rawValue, pathBuffer.baseAddress, pathBuffer.count)
        }
        guard n >= 0 else { return nil }
        return try body(UnsafeBufferPointer(rebasing: pathBuffer[..<Int(n)]))
    }

    /// Facts about `id` in the last search's snapshot.
    public func entry(_ id: FileEntryID) -> FileEntry? {
        var raw = SlickFileEntry()
        guard slick_files_session_entry(session, id.rawValue, &raw) == 0 else { return nil }
        return FileEntry(raw)
    }

    /// The snapshot of the last search, so its hits stay resolvable after the session moves on.
    public func snapshot() -> FileSnapshot? {
        var created: OpaquePointer?
        guard slick_files_session_snapshot(session, &created) == 0, let created else { return nil }
        return FileSnapshot(handle: created)
    }

    /// Highlight ranges of `hit`'s name for the last search, in UTF-16 units. Visible rows only.
    public func highlightRanges(for hit: FileHit) throws(CoreError) -> [HighlightRange] {
        var out: [HighlightRange] = []
        try highlightRanges(for: hit, into: &out)
        return out
    }

    /// Writes the highlight ranges of `hit`'s name into `ranges`, replacing its contents and
    /// keeping its capacity, and returns how many there are.
    @discardableResult
    public func highlightRanges(for hit: FileHit, into ranges: inout [HighlightRange]) throws(CoreError) -> Int {
        var raw = hit.raw
        let status = slick_files_ranges(session, &raw, self.ranges.baseAddress, self.ranges.count)
        return try RangeCopy.replace(&ranges, from: self.ranges, status: status)
    }

    /// Runs `body` with `string`'s UTF-8: in place for native strings, else through scratch space
    /// (truncated at 1 KB on a character boundary). Neither path allocates.
    private func withUTF8(of string: String, _ body: (UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
        if let status = string.utf8.withContiguousStorageIfAvailable({ body($0.baseAddress, $0.count) }) {
            return status
        }
        var n = 0
        var boundary = 0
        for byte in string.utf8 {
            if n == scratch.count { break }
            if byte & 0xC0 != 0x80 { boundary = n }
            scratch[n] = byte
            n += 1
        }
        if n == scratch.count { n = boundary }
        return body(UnsafePointer(scratch.baseAddress), n)
    }
}

/// Reads a path through a measure-then-copy C call into a new String.
enum FilePaths {
    static func string(_ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32) -> String? {
        let n = Int(call(nil, 0))
        guard n > 0 else { return nil }
        var ok = true
        let s = String(unsafeUninitializedCapacity: n) { buffer in
            let written = Int(call(buffer.baseAddress, buffer.count))
            ok = written == n
            return ok ? n : 0
        }
        return ok ? s : nil
    }
}
