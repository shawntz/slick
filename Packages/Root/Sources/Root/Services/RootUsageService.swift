import Foundation
import Kit
import Synchronization

/// ``UsageService`` over root search's memory, so a feature's uses and root search's runs share one
/// store, one file and one forget.
nonisolated final class RootUsageService: UsageService {
    private let memory: ItemMemory
    private let clock: any ClockService
    private let removal = Mutex<(@Sendable () -> Void)?>(nil)

    init(memory: ItemMemory, clock: any ClockService) {
        self.memory = memory
        self.clock = clock
    }

    /// Called from any thread after a forget removed a remembered row, so root search rebuilds its
    /// catalog without it.
    func onRememberedRowRemoved(_ action: @escaping @Sendable () -> Void) {
        removal.withLock { $0 = action }
    }

    func recordUse(of id: ItemID, snapshot: Row?) {
        memory.recordUse(of: id, snapshot: snapshot, at: clock.now)
    }

    func recentlyUsed(namespace: String, limit: Int) -> [UsageRecord] {
        memory.recentlyUsed(namespace: namespace, limit: limit)
    }

    func useCount(of id: ItemID) -> Int {
        memory.useCount(of: id)
    }

    func frecency(namespace: String) -> [ItemID: Double] {
        memory.frecency(namespace: namespace, now: clock.now)
    }

    func forget(_ id: ItemID) {
        if memory.forget(id) { notifyRemoval() }
    }

    func forgetAll(namespace: String) {
        if memory.forgetAll(namespace: namespace) { notifyRemoval() }
    }

    private func notifyRemoval() {
        removal.withLock { $0 }?()
    }
}
