import Foundation

/// Watches folders for changes, such as a folder of script commands.
///
/// A stream that ends while its consumer still reads it means the system refused to watch, or
/// stopped: nothing more will arrive. A feature that depends on the changes should say so where the
/// user looks, such as in its status, and may watch again later. It never ends by itself otherwise.
public protocol FileWatchService: Sendable {
    /// Yields the paths that changed under the folders, coalesced over a short interval. Each call
    /// returns its own stream; watching stops when the consuming task is cancelled.
    func watch(_ directories: [URL]) -> AsyncStream<[URL]>

    /// Yields what changed under the folders with everything the live watcher knows about each
    /// change, for a file index: the flags that ask for a rescan, and each change's event ID. Each call
    /// returns its own stream; watching stops when the consuming task is cancelled.
    ///
    /// Save each batch's ``FileChangeBatch/mark`` once the batch is handled. After a relaunch, pass
    /// the last one as `since`: the watcher first replays what changed after it, then sends one change
    /// flagged ``FileChangeFlags/historyDone`` for each folder. A folder whose history is gone, such as
    /// after macOS discarded its volume's event database, gets one change flagged
    /// ``FileChangeFlags/mustScanSubdirectories`` and ``FileChangeFlags/historyDone`` instead, so
    /// the index reads it again. Without `since`, the stream starts now and sends no history.
    ///
    /// A change made a moment before the call may not be in the history yet. It then arrives as a
    /// live change right after ``FileChangeFlags/historyDone``, so nothing is lost either way.
    ///
    /// Every change names a path inside one of the folders, in the caller's spelling. A notice about
    /// the whole stream, such as dropped events, comes as one change per folder it covers.
    func watchChanges(_ directories: [URL], since mark: FileChangeMark?) -> AsyncStream<FileChangeBatch>
}

extension FileWatchService {
    /// For a watcher that keeps no history: every change from ``watch(_:)`` with no flags and ID
    /// zero, and no marks. With `since`, every folder gets a rescan first, because nothing can be
    /// replayed.
    public func watchChanges(_ directories: [URL], since mark: FileChangeMark?) -> AsyncStream<FileChangeBatch> {
        let changes = watch(directories)
        let rescan = mark == nil ? nil : FileChangeBatch(directories.map { FileChange($0, flags: .lostHistory) })
        return AsyncStream { continuation in
            let task = Task {
                if let rescan { continuation.yield(rescan) }
                for await paths in changes {
                    continuation.yield(FileChangeBatch(paths.map { FileChange($0) }))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One change under a watched folder.
public struct FileChange: Hashable, Sendable {
    /// The path that changed, in the spelling of the folder the caller watches.
    public var url: URL
    public var flags: FileChangeFlags
    /// The event's ID in FSEvents' history. Zero for a root change, for a notice the watcher made
    /// itself, and from a watcher that keeps no history.
    public var id: UInt64

    public init(_ url: URL, flags: FileChangeFlags = [], id: UInt64 = 0) {
        self.url = url
        self.flags = flags
        self.id = id
    }
}

/// What FSEvents says about a change. The first group asks the index to act; the rest describe the
/// item and are hints only, because FSEvents coalesces them.
public struct FileChangeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Read this path and everything below it again: changes were coalesced or lost.
    public static let mustScanSubdirectories = FileChangeFlags(rawValue: 1 << 0)
    /// Events were dropped in this process. Comes with ``mustScanSubdirectories``.
    public static let userDropped = FileChangeFlags(rawValue: 1 << 1)
    /// Events were dropped in the kernel. Comes with ``mustScanSubdirectories``.
    public static let kernelDropped = FileChangeFlags(rawValue: 1 << 2)
    /// The event ID counter wrapped around, so every saved mark is worthless.
    public static let eventIDsWrapped = FileChangeFlags(rawValue: 1 << 3)
    /// The history asked for with `since` has been delivered for this folder. What follows is live.
    public static let historyDone = FileChangeFlags(rawValue: 1 << 4)
    /// The watched folder itself, or a folder above it, was moved, renamed or deleted. The path is
    /// the watched folder, which may no longer exist.
    public static let rootChanged = FileChangeFlags(rawValue: 1 << 5)
    /// A volume was mounted at this path.
    public static let mount = FileChangeFlags(rawValue: 1 << 6)
    /// A volume was unmounted from this path.
    public static let unmount = FileChangeFlags(rawValue: 1 << 7)

    public static let created = FileChangeFlags(rawValue: 1 << 8)
    public static let removed = FileChangeFlags(rawValue: 1 << 9)
    public static let renamed = FileChangeFlags(rawValue: 1 << 10)
    /// The item's contents changed.
    public static let modified = FileChangeFlags(rawValue: 1 << 11)
    /// The item's metadata changed: its attributes, owner, Finder info or extended attributes.
    public static let metadataModified = FileChangeFlags(rawValue: 1 << 12)
    public static let isFile = FileChangeFlags(rawValue: 1 << 13)
    public static let isDirectory = FileChangeFlags(rawValue: 1 << 14)
    public static let isSymlink = FileChangeFlags(rawValue: 1 << 15)

    /// A folder whose history could not be replayed: read it again, and nothing more will be replayed.
    public static let lostHistory: FileChangeFlags = [.mustScanSubdirectories, .historyDone]

    /// True when the path and everything below it must be read again rather than patched: a rescan,
    /// a root change, a mount or an unmount.
    public var requiresRescan: Bool {
        !intersection([.mustScanSubdirectories, .rootChanged, .mount, .unmount]).isEmpty
    }
}

/// Where a watch can pick up after a relaunch. Save it as it comes, and pass it back as `since`.
public struct FileChangeMark: Hashable, Sendable, Codable {
    /// The last event ID handled.
    public var eventID: UInt64
    /// For each watched folder's path, the identity of the event history of the volume it lies on,
    /// when the mark was made. A folder whose identity changed or was unknown is read again rather
    /// than replayed.
    public var histories: [String: String]

    public init(eventID: UInt64, histories: [String: String]) {
        self.eventID = eventID
        self.histories = histories
    }
}

/// The events FSEvents delivered at once, and the mark to save once they are handled.
public struct FileChangeBatch: Hashable, Sendable {
    public var events: [FileChange]
    /// Nil from a watcher that keeps no history, or before the live watcher knows a position.
    public var mark: FileChangeMark?

    public init(_ events: [FileChange], mark: FileChangeMark? = nil) {
        self.events = events
        self.mark = mark
    }
}
