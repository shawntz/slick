import CoreServices
import Foundation
import Kit
import Synchronization

/// The live file watcher, on FSEvents.
///
/// Each ``watch(_:)`` call opens its own event stream with per-file events. FSEvents coalesces
/// changes over ``latency`` and reports real paths, such as `/private/var/...` for a folder under
/// `/var`; the watcher maps them back to the spelling of the folder the caller asked for. Watching
/// stops when the consuming task is cancelled.
nonisolated public final class FSEventsWatcher: FileWatchService {
    /// How long FSEvents gathers changes before it reports them.
    public let latency: Duration
    private let open = Atomic<Int>(0)

    public init(latency: Duration = .milliseconds(200)) {
        self.latency = latency
    }

    /// How many event streams are open.
    public var openStreamCount: Int {
        open.load(ordering: .relaxed)
    }

    public func watch(_ directories: [URL]) -> AsyncStream<[URL]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [URL].self)
        let mapper = WatchedPaths(directories)
        let watch = EventStreamWatch(paths: mapper, latency: latency, continuation: continuation)
        guard !directories.isEmpty, watch.start() else {
            continuation.finish()
            return stream
        }
        open.add(1, ordering: .relaxed)
        continuation.onTermination = { [weak self] _ in
            watch.stop()
            self?.open.subtract(1, ordering: .relaxed)
        }
        return stream
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

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// One FSEvents stream. Every call to the stream happens on its private queue.
nonisolated final class EventStreamWatch: @unchecked Sendable {
    private let paths: WatchedPaths
    private let latency: Duration
    private let continuation: AsyncStream<[URL]>.Continuation
    private let queue = DispatchQueue(label: "platform.fsevents", qos: .utility)
    /// Touched only on `queue`.
    private var stream: FSEventStreamRef?

    init(paths: WatchedPaths, latency: Duration, continuation: AsyncStream<[URL]>.Continuation) {
        self.paths = paths
        self.latency = latency
        self.continuation = continuation
    }

    /// Creates and starts the stream. False when FSEvents refused.
    func start() -> Bool {
        queue.sync {
            // The stream holds this object unretained; `stop()` keeps it alive until the stream is
            // gone, and no callback runs after FSEventStreamInvalidate.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes)
            let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watch = Unmanaged<EventStreamWatch>.fromOpaque(info).takeUnretainedValue()
                let reported = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                watch.deliver(reported)
            }
            guard
                let created = FSEventStreamCreate(
                    nil, callback, &context, paths.realPaths as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency.timeInterval, flags)
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

    private func deliver(_ reported: [String]) {
        let urls = paths.requestedURLs(forEventPaths: reported)
        if !urls.isEmpty { continuation.yield(urls) }
    }
}
