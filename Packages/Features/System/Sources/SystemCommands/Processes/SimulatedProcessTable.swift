import Foundation
import Synchronization

/// Processes that exist only in memory, for scenarios, self-tests and tests. Each snapshot moves
/// time on by one second, and each process uses CPU at its own fixed rate. Quitting removes a
/// process and records the request; no real process is touched.
nonisolated final class SimulatedProcessTable: ProcessTable {
    /// What a caller asked the table to do.
    enum Request: Hashable, Sendable {
        case quit(pid: Int32)
        case forceQuit(pid: Int32)
    }

    private struct State {
        var processes: [ProcessSample]
        /// CPU nanoseconds each process uses per simulated second, by PID.
        var rates: [Int32: UInt64]
        var ownPID: Int32
        var uptime: UInt64 = 1_000_000_000_000
        var requests: [Request] = []
        var snapshots = 0
        /// Processes that ignore a polite quit, as a stuck process does.
        var ignoresQuit: Set<Int32> = []
    }

    static let second: UInt64 = 1_000_000_000

    private let state: Mutex<State>

    /// - Parameters:
    ///   - rates: CPU use per process as a share of one core: 0.5 is 50 percent.
    init(_ processes: [ProcessSample], rates: [Int32: Double] = [:], ownPID: Int32 = 99) {
        let nanoseconds = rates.mapValues { UInt64($0 * Double(Self.second)) }
        state = Mutex(State(processes: processes, rates: nanoseconds, ownPID: ownPID))
    }

    /// Every request, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// How many snapshots were taken.
    var snapshotCount: Int { state.withLock { $0.snapshots } }

    /// Starts a process, as if the user opened something.
    func launch(_ process: ProcessSample, rate: Double = 0) {
        state.withLock { state in
            state.processes.append(process)
            state.rates[process.pid] = UInt64(rate * Double(Self.second))
        }
    }

    /// Ends a process, as if it quit by itself.
    func exit(_ pid: Int32) {
        state.withLock { $0.processes.removeAll { $0.pid == pid } }
    }

    /// Changes how busy a process is from the next snapshot on.
    func setRate(_ rate: Double, of pid: Int32) {
        state.withLock { $0.rates[pid] = UInt64(rate * Double(Self.second)) }
    }

    /// Changes a process's memory from the next snapshot on.
    func setMemory(_ bytes: UInt64, of pid: Int32) {
        state.withLock { state in
            if let index = state.processes.firstIndex(where: { $0.pid == pid }) {
                state.processes[index].memory = bytes
            }
        }
    }

    /// Makes a process ignore polite quit requests.
    func ignoreQuit(_ pid: Int32) {
        state.withLock { _ = $0.ignoresQuit.insert(pid) }
    }

    func snapshot() async throws -> ProcessSnapshot {
        state.withLock { state in
            if state.snapshots > 0 {
                state.uptime += Self.second
                for index in state.processes.indices {
                    state.processes[index].cpuTime += state.rates[state.processes[index].pid] ?? 0
                }
            }
            state.snapshots += 1
            return ProcessSnapshot(uptime: state.uptime, ownPID: state.ownPID, processes: state.processes)
        }
    }

    func quit(_ process: ProcessIdentity) async throws {
        try state.withLock { state in
            try Self.find(process, in: state)
            state.requests.append(.quit(pid: process.pid))
            if !state.ignoresQuit.contains(process.pid) {
                state.processes.removeAll { $0.pid == process.pid }
            }
        }
    }

    func forceQuit(_ process: ProcessIdentity) async throws {
        try state.withLock { state in
            try Self.find(process, in: state)
            state.requests.append(.forceQuit(pid: process.pid))
            state.processes.removeAll { $0.pid == process.pid }
        }
    }

    /// Throws, as the live table does, when the process is gone, its PID was reused, or the list
    /// protects it.
    private static func find(_ process: ProcessIdentity, in state: State) throws {
        guard process.pid > 1, process.pid != state.ownPID else { throw SystemFailure.protected }
        guard
            let current = state.processes.first(where: {
                $0.pid == process.pid && $0.startTime == process.startTime
            })
        else {
            throw SystemFailure.notFound
        }
        if ProcessPolicy.isProtected(process, ownPID: state.ownPID)
            || ProcessPolicy.isProtected(current, ownPID: state.ownPID)
        {
            throw SystemFailure.protected
        }
    }

    /// A small set of made-up processes for scenarios and benchmarks.
    static func example() -> SimulatedProcessTable {
        let processes = [
            sample(2_001, "Example Editor", app: "com.example.editor", memory: 420 << 20),
            sample(2_002, "Example Browser", app: "com.example.browser", memory: 1_300 << 20),
            sample(2_003, "example-indexer", memory: 96 << 20),
            sample(2_004, "example-sync", memory: 38 << 20),
        ]
        return SimulatedProcessTable(processes, rates: [2_001: 0.04, 2_002: 0.22, 2_003: 0.65, 2_004: 0.01])
    }

    /// A made-up process. An app gets a bundle ID, a bundle path and a Dock icon.
    static func sample(
        _ pid: Int32, _ name: String, app bundleID: String? = nil, memory: UInt64 = 10 << 20, startTime: UInt64? = nil
    ) -> ProcessSample {
        let bundlePath = bundleID.map { _ in "/Applications/\(name).app" }
        return ProcessSample(
            pid: pid, startTime: startTime ?? 1_700_000_000_000_000 + UInt64(pid), name: name,
            path: bundlePath.map { "\($0)/Contents/MacOS/\(name)" } ?? "/usr/local/libexec/\(name)", bundleID: bundleID,
            bundlePath: bundlePath, isApplication: bundleID != nil, isRegularApp: bundleID != nil, cpuTime: 0,
            memory: memory)
    }
}
