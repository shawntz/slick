import Foundation
import Kit
import Synchronization

/// A file watcher that reports only the changes a test announces with ``simulateChange(_:)`` or
/// ``simulateEvents(_:mark:)``.
///
/// A path matches a watched folder when it is the folder or lies below it, compared by path only,
/// so a file that no longer exists still matches. `/private/var`, `/private/tmp` and
/// `/private/etc` match `/var`, `/tmp` and `/etc`, as on a real Mac.
public final class FakeFileWatcher: FileWatchService {
    private let watched = Mutex<[Int: [URL]]>([:])
    private let marks = Mutex<[FileChangeMark?]>([])
    private let nextID = Atomic<Int>(0)
    private let broadcast = FakeBroadcast<Delivery>()

    /// What one simulated callback carries.
    private struct Delivery: Sendable {
        var events: [FileChange]
        var mark: FileChangeMark?
    }

    public init() {}

    /// The folders currently watched.
    public var watchedDirectories: [URL] {
        watched.withLock { $0.values.flatMap(\.self) }
    }

    /// The `since` mark of each ``watchChanges(_:since:)`` call, in order. The fake replays nothing by
    /// itself: a test plays the history, then the ``FileChangeFlags/historyDone`` events, with
    /// ``simulateEvents(_:mark:)``.
    public var requestedMarks: [FileChangeMark?] {
        marks.withLock { $0 }
    }

    /// Tells every watcher whose folders contain one of the paths that those paths changed.
    public func simulateChange(_ paths: [URL]) {
        broadcast.send(Delivery(events: paths.map { FileChange($0) }))
    }

    /// Plays one FSEvents callback. An event inside a watcher's folders reaches it. A rescan, a drop
    /// or a wrapped counter reported for a path above its folders reaches it once for each folder
    /// below that path, as the live watcher sends it. ``watch(_:)`` streams hear the paths;
    /// ``watchChanges(_:since:)`` streams hear the events, in their folder's spelling, with `mark`.
    public func simulateEvents(_ events: [FileChange], mark: FileChangeMark? = nil) {
        broadcast.send(Delivery(events: events, mark: mark))
    }

    /// Returns once every watcher has handled every change it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    public func watch(_ directories: [URL]) -> AsyncStream<[URL]> {
        let folders = WatchedFolders(directories)
        return broadcast.stream(onEnd: register(directories)) { delivery in
            let paths = delivery.events.flatMap { event in
                folders.contains(event.url) ? [event.url] : folders.below(event)
            }
            return paths.isEmpty ? nil : paths
        }
    }

    public func watchChanges(_ directories: [URL], since mark: FileChangeMark?) -> AsyncStream<FileChangeBatch> {
        marks.withLock { $0.append(mark) }
        let folders = WatchedFolders(directories)
        return broadcast.stream(onEnd: register(directories)) { delivery in
            let events = delivery.events.flatMap { event -> [FileChange] in
                if let url = folders.inCallersSpelling(event.url) {
                    return [FileChange(url, flags: event.flags, id: event.id)]
                }
                return folders.below(event).map { FileChange($0, flags: event.flags, id: event.id) }
            }
            return events.isEmpty ? nil : FileChangeBatch(events, mark: delivery.mark)
        }
    }

    /// Records the folders as watched and returns what forgets them.
    private func register(_ directories: [URL]) -> @Sendable () -> Void {
        let id = nextID.add(1, ordering: .relaxed).newValue
        watched.withLock { $0[id] = directories }
        return { [weak self] in _ = self?.watched.withLock { $0.removeValue(forKey: id) } }
    }
}

/// One watcher's folders, compared by path alone.
private struct WatchedFolders: Sendable {
    /// Each folder as the caller gave it, and its path for comparing.
    let folders: [(url: URL, path: String)]

    init(_ directories: [URL]) {
        folders = directories.map { ($0, Self.comparable($0)) }
    }

    /// True when the URL is a folder or lies below one.
    func contains(_ url: URL) -> Bool {
        inCallersSpelling(url) != nil
    }

    /// The URL rewritten below the folder it lies in, in the caller's spelling of that folder.
    func inCallersSpelling(_ url: URL) -> URL? {
        let path = Self.comparable(url)
        for folder in folders where Self.isInside(path, folder.path) {
            let rest = path.dropFirst(folder.path == "/" ? 0 : folder.path.count)
            guard !rest.isEmpty else { return folder.url }
            let hint: URL.DirectoryHint = url.hasDirectoryPath ? .isDirectory : .notDirectory
            return folder.url.appending(path: String(rest.drop { $0 == "/" }), directoryHint: hint)
        }
        return nil
    }

    /// The folders a stream-wide notice about a path above them reaches.
    func below(_ event: FileChange) -> [URL] {
        let notices: FileChangeFlags = [.mustScanSubdirectories, .userDropped, .kernelDropped, .eventIDsWrapped]
        guard !event.flags.intersection(notices).isEmpty else { return [] }
        let path = Self.comparable(event.url)
        return folders.filter { Self.isInside($0.path, path) }.map(\.url)
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// The path without `.` or `..`, a trailing `/`, or the `/private` in front of `/var`, `/tmp`
    /// and `/etc`. Reads nothing from disk.
    static func comparable(_ url: URL) -> String {
        var path = url.standardized.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for linked in ["/var", "/tmp", "/etc"] {
            let real = "/private" + linked
            if path == real || path.hasPrefix(real + "/") {
                path.removeFirst("/private".count)
                break
            }
        }
        return path
    }
}
