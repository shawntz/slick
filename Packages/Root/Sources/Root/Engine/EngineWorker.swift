import CoreBridge
import Darwin
import Foundation
import Synchronization

/// The engine and the serial queue that changes it.
///
/// Opening, catalog rebuilds, learning, context and alias changes run here, in the order they were
/// sent, off the main thread. Queries do not: the main thread reads the engine directly, under the
/// engine's own read lock, so a keystroke never waits for this queue.
nonisolated final class EngineWorker: Sendable {
    private let queue = DispatchQueue(label: "root.engine", qos: .userInitiated)
    private let engine = Mutex<Engine?>(nil)
    private let graveyard = Mutex<[any Sendable]>([])

    /// Opens the engine on the queue, so every later ``perform(_:)`` sees it, and calls `done` there.
    func open(directory: URL?, done: @escaping @Sendable (Engine?, RootStatus) -> Void) {
        queue.async {
            let (opened, status) = EngineOpener.open(directory: directory)
            self.engine.withLock { $0 = opened }
            done(opened, status)
        }
    }

    /// Runs `work` on the queue with the engine, which is nil when it could not be made or after
    /// ``close()``.
    func perform(_ work: @escaping @Sendable (Engine?) -> Void) {
        queue.async {
            work(self.engine.withLock { $0 })
        }
    }

    /// Keeps `value` until the next ``sweep()``, which frees it on the queue instead of the caller's
    /// thread, such as an old catalog table whose rows would take the main thread a while to free.
    /// The caller must drop its own reference before it calls ``sweep()``.
    func bury(_ value: any Sendable) {
        graveyard.withLock { $0.append(value) }
    }

    /// Frees what ``bury(_:)`` kept, on the queue.
    func sweep() {
        queue.async {
            let dead = self.graveyard.withLock { graveyard in
                defer { graveyard = [] }
                return graveyard
            }
            withExtendedLifetime(dead) {}
        }
    }

    /// Returns once everything sent so far has run.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Writes what the engine logged, then lets the engine go. The engine closes when the last
    /// reference to it goes away, which frees its data folder for another engine.
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                var closing = self.engine.withLock { engine in
                    defer { engine = nil }
                    return engine
                }
                try? closing?.flush()
                // Drop the reference before resuming, so a caller that opens the same folder next
                // finds it free when this was the last reference.
                closing = nil
                continuation.resume()
            }
        }
    }
}

/// Opens the engine where the configuration says, and falls back to memory when that fails.
nonisolated enum EngineOpener {
    /// The engine and what to tell the user about it. Blocks: a missing snapshot means a full log
    /// replay, about 800 ms at 50,000 events. Never call it on the main thread.
    static func open(directory: URL?) -> (Engine?, RootStatus) {
        guard let directory else {
            return inMemory(status: .ready(persistent: false))
        }
        do throws(CoreError) {
            return (try Engine(directory: directory.path(percentEncoded: false)), .ready(persistent: true))
        } catch .io {
            let reason: RootStatus.InMemoryReason = isHeld(directory) ? .directoryInUse : .directoryUnusable
            return inMemory(status: .inMemory(reason))
        } catch {
            return (nil, .failed("The search engine could not start: \(error)."))
        }
    }

    private static func inMemory(status: RootStatus) -> (Engine?, RootStatus) {
        do throws(CoreError) {
            return (try Engine(), status)
        } catch {
            return (nil, .failed("The search engine could not start: \(error)."))
        }
    }

    /// True when another engine holds the folder: it keeps an exclusive advisory lock on its event
    /// log for as long as it is open, in this process or another.
    static func isHeld(_ directory: URL) -> Bool {
        let log = directory.appending(path: "events.log", directoryHint: .notDirectory)
        let descriptor = Darwin.open(log.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
