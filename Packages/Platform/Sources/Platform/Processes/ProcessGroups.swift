import Darwin
import Synchronization

/// The process groups one runner started and has not reaped yet, and the only place in Platform
/// that sends a signal.
///
/// Every process the runner spawns leads a group of its own, whose ID is the leader's process ID.
/// A group is live from the moment its spawn succeeds until the moment before its leader is
/// reaped. While the leader is unreaped its ID cannot be given to another process, so a signal to a
/// live group can only reach the processes that command started. ``send(_:toGroup:)`` checks that
/// and refuses everything else, so a mistake elsewhere cannot signal a process that is not ours.
nonisolated final class ProcessGroups: Sendable {
    /// The system call that signals a whole group. Tests pass a recorder instead.
    typealias SystemCall = @Sendable (_ group: pid_t, _ signal: Int32) -> Int32

    /// `killpg(2)`.
    static let signalGroup: SystemCall = { group, signal in killpg(group, signal) }

    private let live = Mutex<Set<pid_t>>([])
    private let systemCall: SystemCall

    init(systemCall: @escaping SystemCall = ProcessGroups.signalGroup) {
        self.systemCall = systemCall
    }

    /// The groups that are live now.
    var liveGroups: Set<pid_t> {
        live.withLock { $0 }
    }

    /// Makes a group live. Call it once, right after a spawn succeeded, with the new leader's
    /// process ID. An ID below 2 is never admitted.
    func admit(_ group: pid_t) {
        guard group >= 2 else { return }
        _ = live.withLock { $0.insert(group) }
    }

    /// Ends a group's life. Call it right before reaping its leader, so no signal can follow the
    /// reap and reach a process that got the ID later.
    func retire(_ group: pid_t) {
        _ = live.withLock { $0.remove(group) }
    }

    /// Sends `signal` to every process in `group`, and says whether the system took it.
    ///
    /// Refuses any ID below 2 and any group that is not live. The check and the system call happen
    /// under one lock, and ``retire(_:)`` takes the same lock, so a signal never lands after the
    /// leader's reap.
    @discardableResult
    func send(_ signal: Int32, toGroup group: pid_t) -> Bool {
        live.withLock { live in
            guard group >= 2, live.contains(group) else { return false }
            return systemCall(group, signal) == 0
        }
    }
}
