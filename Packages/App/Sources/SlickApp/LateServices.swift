import Foundation
import Kit
import Synchronization

/// The usage service features get, forwarding to Root's once Root exists.
///
/// The composition has a cycle: features need Root's usage service and fuzzy index in their
/// `Services`, while Root needs the feature runtime as its `FeatureDirectory`. App breaks it by
/// giving the runtime these two forwarders, making Root over the runtime, and then pointing the
/// forwarders at Root. Features are activated only after that, so in practice no call reaches the
/// fallback.
nonisolated final class LateUsageService: UsageService {
    private let target = Mutex<(any UsageService)?>(nil)

    init() {}

    /// Points every later call at `service`.
    func connect(_ service: any UsageService) {
        target.withLock { $0 = service }
    }

    var isConnected: Bool { target.withLock { $0 != nil } }

    private var current: (any UsageService)? { target.withLock { $0 } }

    func recordUse(of id: ItemID, snapshot: Row?) {
        current?.recordUse(of: id, snapshot: snapshot)
    }

    func recentlyUsed(namespace: String, limit: Int) -> [UsageRecord] {
        current?.recentlyUsed(namespace: namespace, limit: limit) ?? []
    }

    func useCount(of id: ItemID) -> Int {
        current?.useCount(of: id) ?? 0
    }

    func frecency(namespace: String) -> [ItemID: Double] {
        current?.frecency(namespace: namespace) ?? [:]
    }

    func forget(_ id: ItemID) {
        current?.forget(id)
    }

    func forgetAll(namespace: String) {
        current?.forgetAll(namespace: namespace)
    }
}

/// The fuzzy index service features get, forwarding to Root's once Root exists. Before that it
/// makes an index that finds nothing.
nonisolated final class LateFuzzyIndexService: FuzzyIndexService {
    private let target = Mutex<(any FuzzyIndexService)?>(nil)

    init() {}

    func connect(_ service: any FuzzyIndexService) {
        target.withLock { $0 = service }
    }

    var isConnected: Bool { target.withLock { $0 != nil } }

    @concurrent func makeIndex(_ entries: [FuzzyEntry]) async -> any FuzzyIndex {
        guard let service = target.withLock({ $0 }) else { return EmptyFuzzyIndex(count: entries.count) }
        return await service.makeIndex(entries)
    }
}

/// An index that matches nothing.
nonisolated struct EmptyFuzzyIndex: FuzzyIndex {
    let count: Int

    func search(_ query: String, limit: Int) -> [FuzzyMatch] { [] }
}
