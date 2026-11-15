import Foundation
import Kit
import Synchronization

/// A file watcher that reports only the changes a test announces with ``simulateChange(_:)``.
public final class FakeFileWatcher: FileWatchService {
    private let watched = Mutex<[Int: [URL]]>([:])
    private let nextID = Atomic<Int>(0)
    private let broadcast = FakeBroadcast<[URL]>()

    public init() {}

    /// The folders currently watched.
    public var watchedDirectories: [URL] {
        watched.withLock { $0.values.flatMap(\.self) }
    }

    /// Tells every watcher whose folders contain one of the paths that those paths changed.
    public func simulateChange(_ paths: [URL]) {
        broadcast.send(paths)
    }

    /// Returns once every watcher has handled every change it received.
    public func settle() async {
        await broadcast.waitUntilIdle()
    }

    var isSettled: Bool { broadcast.isIdle }

    public func watch(_ directories: [URL]) -> AsyncStream<[URL]> {
        let id = nextID.add(1, ordering: .relaxed).newValue
        watched.withLock { $0[id] = directories }
        let folders = directories.map(\.standardizedFileURL.path)
        let insideFolders: @Sendable ([URL]) -> [URL]? = { paths in
            let inside = paths.filter { path in folders.contains { path.standardizedFileURL.path.hasPrefix($0) } }
            return inside.isEmpty ? nil : inside
        }
        let unwatch: @Sendable () -> Void = { [weak self] in _ = self?.watched.withLock { $0.removeValue(forKey: id) } }
        return broadcast.stream(onEnd: unwatch, insideFolders)
    }
}
