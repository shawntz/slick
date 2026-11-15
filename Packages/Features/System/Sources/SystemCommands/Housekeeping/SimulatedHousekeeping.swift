import Foundation
import Synchronization

/// A Trash, disks and a Finder setting that exist only in memory, for scenarios, self-tests and
/// tests. Nothing on disk is read or deleted, and nothing is ejected.
nonisolated final class SimulatedHousekeeping: HousekeepingService {
    /// What a caller asked the service to do.
    enum Request: Hashable, Sendable {
        case emptyTrash(includingVolumes: Bool)
        case eject(path: String, keepingOtherPartitions: Bool)
        case setShowsHiddenFiles(Bool)
    }

    private struct State {
        var trashItems: Int
        var volumeTrashItems: Int
        var disks: [Disk]
        var showsHiddenFiles = false
        var requests: [Request] = []
        /// Items that stay in the Trash, as items in use do.
        var stuckItems = 0
        /// Disks that refuse to eject, as disks in use do.
        var busyDisks: Set<String> = []
        /// Thrown by every Trash call, such as a missing permission.
        var trashFailure: SystemFailure?
        /// False makes Finder stay open instead of restarting, as a busy Finder does.
        var finderRestarts = true
    }

    private let state: Mutex<State>

    init(trashItems: Int = 0, volumeTrashItems: Int = 0, disks: [Disk] = []) {
        state = Mutex(State(trashItems: trashItems, volumeTrashItems: volumeTrashItems, disks: disks))
    }

    /// Every request, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// The disks still mounted.
    var disks: [Disk] { state.withLock { $0.disks } }

    var trashItems: Int { state.withLock { $0.trashItems } }

    var hiddenFilesShown: Bool { state.withLock { $0.showsHiddenFiles } }

    /// Makes every Trash call fail, as when macOS keeps the Trash from the app.
    func failTrash(with failure: SystemFailure?) {
        state.withLock { $0.trashFailure = failure }
    }

    /// Makes this many items refuse to be deleted.
    func keepInTrash(_ count: Int) {
        state.withLock { $0.stuckItems = count }
    }

    /// Makes a disk refuse to eject.
    func makeBusy(_ path: String) {
        state.withLock { _ = $0.busyDisks.insert(path) }
    }

    /// Makes Finder stay open, or restart again, when the hidden files setting changes.
    func setFinderRestarts(_ restarts: Bool) {
        state.withLock { $0.finderRestarts = restarts }
    }

    func trashItemCount(includingVolumes: Bool) async throws -> Int {
        try state.withLock { state in
            if let failure = state.trashFailure { throw failure }
            return state.trashItems + (includingVolumes ? state.volumeTrashItems : 0)
        }
    }

    func emptyTrash(includingVolumes: Bool) async throws -> TrashResult {
        try state.withLock { state in
            if let failure = state.trashFailure { throw failure }
            state.requests.append(.emptyTrash(includingVolumes: includingVolumes))
            let total = state.trashItems + (includingVolumes ? state.volumeTrashItems : 0)
            let failed = min(state.stuckItems, total)
            state.trashItems = failed
            if includingVolumes { state.volumeTrashItems = 0 }
            return TrashResult(deleted: total - failed, failed: failed)
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
