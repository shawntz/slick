import Darwin
import Foundation
import Kit

/// One launcher at a time. A second copy started while one runs asks the running one to open its
/// panel, then quits.
///
/// The live launcher tells itself apart by a lock on a file in its data folder, held for the life
/// of the process. Selftests, benches and scenarios use temporary data folders and never take it,
/// so one of them running never makes the launcher quit, and they may run beside it.
enum SingleInstance {
    /// The distributed notification a second copy posts.
    static let summonNotification = Notification.Name(Brand.bundleID + ".summon")

    /// The lock file's name in the data folder.
    nonisolated static let lockFileName = "launcher.lock"

    /// What taking the lock found.
    nonisolated enum LockResult {
        /// This process holds the lock now. Keep the value for the life of the process.
        case acquired(InstanceLock)
        /// Another process holds it: a launcher on this data folder runs.
        case heldElsewhere
        /// The lock file could not be opened. The launcher runs without the check.
        case unavailable(errno: Int32)
    }

    /// Takes the lock in the data folder.
    nonisolated static func lock(dataRoot: URL) -> LockResult {
        InstanceLock.acquire(at: dataRoot.appending(path: lockFileName))
    }

    /// Asks the running copy to open its panel.
    static func askRunningCopyToSummon() {
        DistributedNotificationCenter.default().postNotificationName(
            summonNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `summon` on the main actor whenever a second copy asks. Returns the observer to remove.
    static func listen(_ summon: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: summonNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { summon() }
        }
    }
}

/// An exclusive `flock` on a file, held while the value lives.
///
/// The kernel drops the lock when the descriptor closes, which also happens when the process ends
/// or crashes, so a stale file never blocks the next launch. The descriptor is closed on exec, so a
/// script the launcher runs never inherits the lock and keeps it after the launcher is gone.
nonisolated final class InstanceLock: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Opens or makes the file and takes the lock without waiting.
    static func acquire(at url: URL) -> SingleInstance.LockResult {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable(errno: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            return failure == EWOULDBLOCK ? .heldElsewhere : .unavailable(errno: failure)
        }
        return .acquired(InstanceLock(descriptor: descriptor))
    }
}
