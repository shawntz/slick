import CoreServices
import Foundation
import Kit
import Synchronization

/// The live file watcher, on FSEvents.
///
/// Each watch opens its own event stream with per-file events. FSEvents coalesces changes over
/// ``latency`` and reports real paths, such as `/private/var/...` for a folder under `/var`; the
/// watcher maps them back to the spelling of the folder the caller asked for. Watching stops when
/// the consuming task is cancelled.
///
/// ``watch(_:)`` reports paths inside the folders and nothing else. ``watchChanges(_:since:)`` also
/// watches the folders themselves for a move or a delete, carries each event's flags and ID, replays
/// history from a saved mark, and turns a notice about the whole stream, such as dropped events
/// reported for `/`, into one event per folder it covers.
nonisolated public final class FSEventsWatcher: FileWatchService {
    /// How long FSEvents gathers changes before it reports them.
    public let latency: Duration
    private let history: any FileChangeHistory
    private let open = Atomic<Int>(0)

    /// - Parameter history: Where event IDs and volume history identities come from. Tests pass a
    ///   fixed one.
    public init(latency: Duration = .milliseconds(200), history: any FileChangeHistory = LiveFileChangeHistory()) {
        self.latency = latency
        self.history = history
    }

    /// How many event streams are open.
    public var openStreamCount: Int {
        open.load(ordering: .relaxed)
    }

    public func watch(_ directories: [URL]) -> AsyncStream<[URL]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [URL].self)
        let mapper = WatchedPaths(directories)
        let watch = EventStreamWatch(paths: mapper.realPaths, latency: latency) { paths, _, _ in
            let urls = mapper.requestedURLs(forEventPaths: paths)
            if !urls.isEmpty { continuation.yield(urls) }
        }
        guard !directories.isEmpty, watch.start() else {
            continuation.finish()
            return stream
        }
        follow(watch, until: continuation)
        return stream
    }

    /// Reads the metadata of each folder, never its contents, to learn which volume's history it
    /// belongs to.
    public func watchChanges(_ directories: [URL], since mark: FileChangeMark?) -> AsyncStream<FileChangeBatch> {
        let (stream, continuation) = AsyncStream.makeStream(of: FileChangeBatch.self)
        guard !directories.isEmpty else {
            continuation.finish()
            return stream
        }
        let mapper = WatchedPaths(directories)
        var histories: [String: String] = [:]
        for root in mapper.roots {
            histories[root.requested] = history.identity(ofVolumeAt: root.real)
        }
        let currentEventID = history.currentEventID()
        let plan = ResumePlan(
            mark: mark, roots: mapper.roots.map(\.requested), histories: histories, currentEventID: currentEventID)
        let batcher = EventBatcher(paths: mapper, plan: plan, histories: histories, currentEventID: currentEventID)
        // Folders whose history is gone hear so before anything is replayed for the others.
        if let lost = batcher.lostHistoryBatch() { continuation.yield(lost) }
        let watch = EventStreamWatch(
            paths: mapper.realPaths, latency: latency, since: plan.sinceWhen, watchesRoots: true
        ) { paths, flags, ids in
            if let batch = batcher.batch(paths: paths, flags: flags, ids: ids) { continuation.yield(batch) }
        }
        guard watch.start() else {
            continuation.finish()
            return stream
        }
        follow(watch, until: continuation)
        return stream
    }

    /// Counts the watch as open until its consumer goes away, then stops it.
    private func follow<Element>(_ watch: EventStreamWatch, until continuation: AsyncStream<Element>.Continuation) {
        open.add(1, ordering: .relaxed)
        continuation.onTermination = { [weak self] _ in
            watch.stop()
            self?.open.subtract(1, ordering: .relaxed)
        }
    }
}

/// Event IDs and the identity of each volume's event history. ``LiveFileChangeHistory`` asks FSEvents.
nonisolated public protocol FileChangeHistory: Sendable {
    /// The identity of the event database of the volume that holds the path, or nil when FSEvents
    /// keeps none for it, as for most network volumes. It changes when macOS discards the database,
    /// and a saved event ID means nothing after that.
    func identity(ofVolumeAt path: String) -> String?
    /// The newest event ID on this Mac.
    func currentEventID() -> UInt64
}

/// FSEvents' own answers: `stat` for the folder's device, then `FSEventsCopyUUIDForDevice`.
nonisolated public struct LiveFileChangeHistory: FileChangeHistory {
    public init() {}

    public func identity(ofVolumeAt path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }
}

/// Which folders a watch replays from a saved mark, and which it reads again because their history
/// is gone. Pure.
nonisolated struct ResumePlan: Equatable, Sendable {
    /// The event ID to start after, or nil to start now.
    var sinceWhen: UInt64?
    /// Folders, as the caller spelled them, whose history the mark cannot replay.
    var lostRoots: [String]
    /// Folders the stream replays. Each hears ``FileChangeFlags/historyDone`` when FSEvents says the
    /// replay is over.
    var replayingRoots: [String]

    /// - Parameters:
    ///   - roots: The folders in the caller's spelling, in order.
    ///   - histories: Each folder's volume history identity now. A folder without one cannot be
    ///     replayed.
    ///   - currentEventID: The newest event ID now. A mark past it is from a counter that wrapped
    ///     or a history that was replaced, so nothing can be replayed.
    init(mark: FileChangeMark?, roots: [String], histories: [String: String], currentEventID: UInt64) {
        guard let mark else {
            (sinceWhen, lostRoots, replayingRoots) = (nil, [], [])
            return
        }
        let markIsPossible = mark.eventID <= currentEventID
        let replaying = roots.filter { root in
            guard markIsPossible, let now = histories[root], let then = mark.histories[root] else { return false }
            return now == then
        }
        replayingRoots = replaying
        lostRoots = roots.filter { !replaying.contains($0) }
        sinceWhen = replaying.isEmpty ? nil : mark.eventID
    }
}

/// Turns what one FSEvents callback delivered into a batch for the caller, and keeps the mark.
/// Callbacks come one at a time on the stream's queue.
nonisolated final class EventBatcher: Sendable {
    private struct State {
        /// The newest event ID delivered, or where the watch started. Never zero, which FSEvents
        /// reads as "replay everything since the beginning".
        var lastEventID: UInt64
        /// Replayed folders that have not heard that their history is done.
        var awaitingHistory: [String]
    }

    private let paths: WatchedPaths
    private let plan: ResumePlan
    private let histories: [String: String]
    private let state: Mutex<State>

    /// - Parameter currentEventID: The newest event ID when the watch starts. A watch that replays
    ///   nothing starts its mark there.
    init(paths: WatchedPaths, plan: ResumePlan, histories: [String: String], currentEventID: UInt64) {
        self.paths = paths
        self.plan = plan
        self.histories = histories
        state = Mutex(State(lastEventID: plan.sinceWhen ?? currentEventID, awaitingHistory: plan.replayingRoots))
    }

    /// The rescan every folder with lost history needs, or nil when there is none.
    func lostHistoryBatch() -> FileChangeBatch? {
        guard !plan.lostRoots.isEmpty else { return nil }
        let events = plan.lostRoots.map { FileChange(URL(filePath: $0), flags: .lostHistory) }
        return FileChangeBatch(events, mark: state.withLock { mark(after: $0.lastEventID) })
    }

    /// One callback's events, or nil when none of them concerns the folders.
    func batch(paths reported: [String], flags rawFlags: [UInt32], ids: [UInt64]) -> FileChangeBatch? {
        let count = min(reported.count, rawFlags.count, ids.count)
        return state.withLock { state in
            var events: [FileChange] = []
            for index in 0..<count {
                let (path, raw, id) = (reported[index], rawFlags[index], ids[index])
                if id != 0 { state.lastEventID = id }
                let flags = Self.flags(fromFSEvents: raw)
                if flags.contains(.historyDone) {
                    // FSEvents says to ignore this event's path.
                    events += state.awaitingHistory.map { FileChange(URL(filePath: $0), flags: .historyDone, id: id) }
                    state.awaitingHistory = []
                } else if let url = paths.requestedURL(forEventPath: path) {
                    events.append(FileChange(url, flags: flags, id: id))
                } else if Self.concernsWholeStream(flags) {
                    events += paths.roots(under: path).map { FileChange($0, flags: flags, id: id) }
                }
            }
            guard !events.isEmpty else { return nil }
            return FileChangeBatch(events, mark: mark(after: state.lastEventID))
        }
    }

    private func mark(after eventID: UInt64) -> FileChangeMark? {
        guard !histories.isEmpty, eventID != 0 else { return nil }
        return FileChangeMark(eventID: eventID, histories: histories)
    }

    /// Dropped events and a wrapped counter may be reported for a path above the folders, such as `/`.
    private static func concernsWholeStream(_ flags: FileChangeFlags) -> Bool {
        !flags.intersection([.mustScanSubdirectories, .userDropped, .kernelDropped, .eventIDsWrapped]).isEmpty
    }

    /// FSEvents' flag bits as Kit's flags. Unknown bits are dropped.
    static func flags(fromFSEvents raw: UInt32) -> FileChangeFlags {
        let table: [(Int, FileChangeFlags)] = [
            (kFSEventStreamEventFlagMustScanSubDirs, .mustScanSubdirectories),
            (kFSEventStreamEventFlagUserDropped, .userDropped),
            (kFSEventStreamEventFlagKernelDropped, .kernelDropped),
            (kFSEventStreamEventFlagEventIdsWrapped, .eventIDsWrapped),
            (kFSEventStreamEventFlagHistoryDone, .historyDone),
            (kFSEventStreamEventFlagRootChanged, .rootChanged),
            (kFSEventStreamEventFlagMount, .mount),
            (kFSEventStreamEventFlagUnmount, .unmount),
            (kFSEventStreamEventFlagItemCreated, .created),
            (kFSEventStreamEventFlagItemRemoved, .removed),
            (kFSEventStreamEventFlagItemRenamed, .renamed),
            (kFSEventStreamEventFlagItemModified, .modified),
            (kFSEventStreamEventFlagItemInodeMetaMod, .metadataModified),
            (kFSEventStreamEventFlagItemFinderInfoMod, .metadataModified),
            (kFSEventStreamEventFlagItemChangeOwner, .metadataModified),
            (kFSEventStreamEventFlagItemXattrMod, .metadataModified),
            (kFSEventStreamEventFlagItemIsFile, .isFile),
            (kFSEventStreamEventFlagItemIsDir, .isDirectory),
            (kFSEventStreamEventFlagItemIsSymlink, .isSymlink),
        ]
        var flags: FileChangeFlags = []
        for (bit, flag) in table where raw & UInt32(bit) != 0 {
            flags.insert(flag)
        }
        return flags
    }
}

/// The folders one watcher covers, as the caller spelled them and as FSEvents reports them.
nonisolated struct WatchedPaths: Sendable {
    /// Each folder's path as the caller gave it, and its real path, both without a trailing "/".
    let roots: [(requested: String, real: String)]

    init(_ directories: [URL]) {
        roots = directories.map { directory in
            let requested = directory.standardizedFileURL.path(percentEncoded: false)
            return (Self.trimmed(requested), Self.trimmed(Self.realPath(requested)))
        }
    }

    /// The path with every symbolic link resolved, as FSEvents reports it. Unlike
    /// `URL.resolvingSymlinksInPath()`, this keeps the `/private` of `/private/var`. A path that
    /// does not exist stays as it is.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    init(roots: [(requested: String, real: String)]) {
        self.roots = roots.map { (Self.trimmed($0.requested), Self.trimmed($0.real)) }
    }

    /// The real paths to hand FSEvents.
    var realPaths: [String] {
        roots.map(\.real)
    }

    /// An event path in the caller's spelling, or nil when it lies outside every folder.
    func requestedURL(forEventPath path: String) -> URL? {
        let path = Self.trimmed(path)
        for root in roots {
            for prefix in [root.real, root.requested] where path == prefix || path.hasPrefix(prefix + "/") {
                return URL(filePath: root.requested + path.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// The event paths of one batch in the caller's spelling, without duplicates, in order.
    func requestedURLs(forEventPaths paths: [String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for path in paths {
            guard let url = requestedURL(forEventPath: path), seen.insert(url.path(percentEncoded: false)).inserted
            else { continue }
            urls.append(url)
        }
        return urls
    }

    /// The folders that lie at or below `path`, in the caller's spelling. An empty path covers every
    /// folder.
    func roots(under path: String) -> [URL] {
        let path = Self.trimmed(path)
        return roots.filter { root in
            [root.real, root.requested].contains { folder in
                path.isEmpty || path == "/" || folder == path || folder.hasPrefix(path + "/")
            }
        }.map { URL(filePath: $0.requested) }
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// One FSEvents stream. Every call to the stream happens on its private queue.
nonisolated final class EventStreamWatch: @unchecked Sendable {
    /// What one callback delivered: paths, FSEvents flags and event IDs, index by index.
    typealias Delivery = @Sendable (_ paths: [String], _ flags: [UInt32], _ ids: [UInt64]) -> Void

    private let paths: [String]
    private let latency: Duration
    private let since: UInt64?
    private let watchesRoots: Bool
    private let delivery: Delivery
    private let queue = DispatchQueue(label: "platform.fsevents", qos: .utility)
    /// Touched only on `queue`.
    private var stream: FSEventStreamRef?

    /// - Parameters:
    ///   - paths: Real paths, as FSEvents reports them.
    ///   - since: The event ID to replay after, or nil to start now.
    ///   - watchesRoots: Also report a move or delete of a folder itself or of a folder above it.
    init(
        paths: [String], latency: Duration, since: UInt64? = nil, watchesRoots: Bool = false,
        delivery: @escaping Delivery
    ) {
        self.paths = paths
        self.latency = latency
        self.since = since
        self.watchesRoots = watchesRoots
        self.delivery = delivery
    }

    /// Creates and starts the stream. False when FSEvents refused.
    func start() -> Bool {
        queue.sync {
            // The stream holds this object unretained; `stop()` keeps it alive until the stream is
            // gone, and no callback runs after FSEventStreamInvalidate.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            var flags =
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
            if watchesRoots { flags |= kFSEventStreamCreateFlagWatchRoot }
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIDs in
                guard let info else { return }
                let watch = Unmanaged<EventStreamWatch>.fromOpaque(info).takeUnretainedValue()
                let reported = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
                let ids = Array(UnsafeBufferPointer(start: eventIDs, count: count))
                watch.delivery(reported, flags, ids)
            }
            guard
                let created = FSEventStreamCreate(
                    nil, callback, &context, paths as CFArray,
                    since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency.timeInterval,
                    FSEventStreamCreateFlags(flags))
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    /// Stops and releases the stream. Safe to call more than once.
    func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
