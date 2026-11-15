import Foundation
import Synchronization

/// A Trash, disks and a Finder setting that exist only in memory, for scenarios, self-tests and
/// tests. Nothing on disk is read or deleted, and nothing is ejected.
nonisolated final class SimulatedHousekeeping: HousekeepingService {
    /// What a caller asked the service to do.
    enum Request: Hashable, Sendable {
        case emptyTrash
        case eject(path: String, keepingOtherPartitions: Bool)
        case setShowsHiddenFiles(Bool)
    }

    private struct State {
        var trashItems: Int
        var disks: [Disk]
        var showsHiddenFiles = false
        var requests: [Request] = []
        /// False makes Finder give no count, so the question goes without one.
        var countsTrash = true
        /// False makes Finder still be emptying at the end of the wait, as with a large Trash.
        var finishesEmptying = true
        /// Disks that refuse to eject, as disks in use do.
        var busyDisks: Set<String> = []
        /// Thrown by every Trash call, such as a missing permission.
        var trashFailure: SystemFailure?
        /// False makes Finder stay open instead of restarting, as a busy Finder does.
        var finderRestarts = true
    }

    private let state: Mutex<State>

    init(trashItems: Int = 0, disks: [Disk] = []) {
        state = Mutex(State(trashItems: trashItems, disks: disks))
    }

    /// Every request, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// The disks still mounted.
    var disks: [Disk] { state.withLock { $0.disks } }

    var trashItems: Int { state.withLock { $0.trashItems } }

    var hiddenFilesShown: Bool { state.withLock { $0.showsHiddenFiles } }

    /// Makes every Trash call fail, as when Finder may not be sent events yet.
    func failTrash(with failure: SystemFailure?) {
        state.withLock { $0.trashFailure = failure }
    }

    /// Makes Finder give no count, or give one again.
    func setCountsTrash(_ counts: Bool) {
        state.withLock { $0.countsTrash = counts }
    }

    /// Makes Finder still be emptying when the wait ends, or finish in time again.
    func setFinishesEmptying(_ finishes: Bool) {
        state.withLock { $0.finishesEmptying = finishes }
    }

    /// Makes a disk refuse to eject.
    func makeBusy(_ path: String) {
        state.withLock { _ = $0.busyDisks.insert(path) }
    }

    /// Makes Finder stay open, or restart again, when the hidden files setting changes.
    func setFinderRestarts(_ restarts: Bool) {
        state.withLock { $0.finderRestarts = restarts }
    }

    func trashItemCount() async throws -> Int? {
        try state.withLock { state in
            if let failure = state.trashFailure { throw failure }
            return state.countsTrash ? state.trashItems : nil
        }
    }

    func emptyTrash() async throws -> Bool {
        try state.withLock { state in
            if let failure = state.trashFailure { throw failure }
            state.requests.append(.emptyTrash)
            state.trashItems = 0
            return state.finishesEmptying
        }
    }

    func ejectableDisks() async throws -> [Disk] {
        state.withLock { $0.disks }
    }

    func eject(_ disk: Disk, keepingOtherPartitions: Bool) async throws {
        try state.withLock { state in
            state.requests.append(.eject(path: disk.path, keepingOtherPartitions: keepingOtherPartitions))
            if state.busyDisks.contains(disk.path) { throw SystemFailure.failed(code: 16) }
            state.disks.removeAll { $0.path == disk.path }
        }
    }

    func showsHiddenFiles() async throws -> Bool {
        state.withLock { $0.showsHiddenFiles }
    }

    func setShowsHiddenFiles(_ shows: Bool) async throws -> Bool {
        state.withLock { state in
            state.requests.append(.setShowsHiddenFiles(shows))
            state.showsHiddenFiles = shows
            return state.finderRestarts
        }
    }
}
