import Darwin
import Foundation
import Synchronization

/// One spawned process and the group it leads: watching its leader, stopping the group and
/// reaping the leader.
///
/// A thread of its own waits for the leader with `waitid(2)` and `WNOWAIT`, which sees the exit and
/// leaves the leader unreaped. Only then does anything reap it, with `waitpid(2)` on that one
/// process ID, after its group has been retired. So the group's ID stays ours for every signal.
///
/// - A leader that ends by itself is reaped, and nothing is signalled. Children it left in the
///   background keep running, as they do after a command in a terminal.
/// - A stop sends SIGTERM to the group. Once the leader has exited, or once the grace has passed,
///   it sends SIGKILL to the group. The leader is reaped after that.
nonisolated final class ChildProcess: Sendable {
    private enum AtExit {
        case reap
        case killThenReap
    }

    private struct State {
        var hasExited = false
        var isStopping = false
        var killSent = false
        var isReaped = false
        var exitWaiters: [@Sendable () -> Void] = []
    }

    let pid: pid_t
    private let groups: ProcessGroups
    private let onReaped: @Sendable (_ status: Int32) -> Void
    private let state = Mutex(State())

    /// Takes charge of a process that just started and makes its group live. Call ``watch()``
    /// next. `onReaped` gets the exit status as a shell reports it, 128 plus the signal number for a
    /// process a signal ended, or -1 when it cannot be known.
    static func adopt(
        _ pid: pid_t, groups: ProcessGroups, onReaped: @escaping @Sendable (_ status: Int32) -> Void
    ) -> ChildProcess {
        let child = ChildProcess(pid: pid, groups: groups, onReaped: onReaped)
        // Live before anything can reap it, so a reap always retires a live group.
        groups.admit(pid)
        return child
    }

    /// Starts the thread that waits for the leader's exit. Call it once.
    func watch() {
        let watcher = Thread { [self] in waitForExit() }
        watcher.name = "platform.processes.wait"
        watcher.start()
    }

    private init(pid: pid_t, groups: ProcessGroups, onReaped: @escaping @Sendable (_ status: Int32) -> Void) {
        self.pid = pid
        self.groups = groups
        self.onReaped = onReaped
    }

    /// Stops the group: SIGTERM now, then SIGKILL once the leader has exited or `grace` has passed.
    /// A stop that began earlier keeps going, and the shorter grace wins.
    func stop(grace: Duration) {
        terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.timeInterval) { [self] in kill() }
    }

    /// Begins a stop with SIGTERM to the group. Does nothing when the leader already exited by
    /// itself or a stop already began.
    func terminate() {
        let begins = state.withLock { state -> Bool in
            guard !state.hasExited, !state.isStopping else { return false }
            state.isStopping = true
            return true
        }
        if begins { groups.send(SIGTERM, toGroup: pid) }
    }

    /// Ends a stop that began: SIGKILL to the group, once. The leader is reaped when it has exited.
    func kill() {
        let sends = state.withLock { state -> Bool in
            guard state.isStopping, !state.killSent, !state.hasExited else { return false }
            state.killSent = true
            return true
        }
        if sends { groups.send(SIGKILL, toGroup: pid) }
    }

    /// Calls `body` once the leader has exited, at once when it already has.
    func whenExited(_ body: @escaping @Sendable () -> Void) {
        let now = state.withLock { state -> Bool in
            if state.hasExited { return true }
            state.exitWaiters.append(body)
            return false
        }
        if now { body() }
    }

    /// Runs on the watcher thread until the leader exits.
    private func waitForExit() {
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        } while result == -1 && errno == EINTR
        leaderExited(reapable: result == 0)
    }

    private func leaderExited(reapable: Bool) {
        let (atExit, waiters) = state.withLock { state -> (AtExit, [@Sendable () -> Void]) in
            state.hasExited = true
            defer { state.exitWaiters = [] }
            guard state.isStopping, !state.killSent else { return (.reap, state.exitWaiters) }
            state.killSent = true
            return (.killThenReap, state.exitWaiters)
        }
        // A stop that saw the leader go still ends what is left of its group, unless the wait
        // failed and the leader may be gone already.
        if atExit == .killThenReap, reapable { groups.send(SIGKILL, toGroup: pid) }
        reap(reapable: reapable)
        for waiter in waiters { waiter() }
    }

    /// Retires the group, then reaps the leader. `reapable` is false when the wait failed, which
    /// means something else in the app reaped our child; the group is retired all the same.
    private func reap(reapable: Bool) {
        let first = state.withLock { state -> Bool in
            defer { state.isReaped = true }
            return !state.isReaped
        }
        guard first else { return }
        groups.retire(pid)
        var status: Int32 = 0
        var result: pid_t = -1
        if reapable {
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR
        }
        onReaped(result == pid ? Self.shellStatus(status) : -1)
    }

    /// The status as a shell reports it: the exit code, or 128 plus the signal that ended it.
    static func shellStatus(_ status: Int32) -> Int32 {
        // The macros of <sys/wait.h>: _WSTATUS is the low 7 bits, 0177 means stopped.
        let low = status & 0o177
        if low == 0 { return (status >> 8) & 0xff }
        if low != 0o177 { return 128 + low }
        return -1
    }
}
