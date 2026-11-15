import Foundation
import Kit
import Synchronization

/// Usage in memory, stamped with the given clock.
public final class FakeUsage: UsageService {
    private struct Use {
        let id: ItemID
        let snapshot: Row?
        let date: Date
    }

    private let uses = Mutex<[Use]>([])
    private let clock: any ClockService

    public init(clock: any ClockService = SystemClock()) {
        self.clock = clock
    }

    /// Every recorded use, oldest first.
    public var recorded: [ItemID] { uses.withLock { $0.map(\.id) } }

    public func recordUse(of id: ItemID, snapshot: Row?) {
        let date = clock.now
        uses.withLock { $0.append(Use(id: id, snapshot: snapshot, date: date)) }
    }

    public func recentlyUsed(namespace: String, limit: Int) -> [UsageRecord] {
        uses.withLock { uses in
            var records: [ItemID: UsageRecord] = [:]
            var order: [ItemID] = []
            for use in uses.reversed() where use.id.namespace == namespace {
                if var record = records[use.id] {
                    record.count += 1
                    records[use.id] = record
                } else {
                    records[use.id] = UsageRecord(id: use.id, snapshot: use.snapshot, lastUsed: use.date, count: 1)
                    order.append(use.id)
                }
            }
            return order.prefix(max(limit, 0)).compactMap { records[$0] }
        }
    }

    public func useCount(of id: ItemID) -> Int {
        uses.withLock { $0.count { $0.id == id } }
    }

    public func frecency(namespace: String) -> [ItemID: Double] {
        let now = clock.now
        return uses.withLock { uses in
            var scores: [ItemID: Double] = [:]
            for use in uses where use.id.namespace == namespace {
                let weeks = max(0, now.timeIntervalSince(use.date)) / (7 * 86_400)
                scores[use.id, default: 0] += pow(0.5, weeks)
            }
            return scores
        }
    }

    public func forget(_ id: ItemID) {
        uses.withLock { $0.removeAll { $0.id == id } }
    }

    public func forgetAll(namespace: String) {
        uses.withLock { $0.removeAll { $0.id.namespace == namespace } }
    }
}
