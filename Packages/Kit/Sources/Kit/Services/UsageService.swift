import Foundation

/// What the user has used, for recents and ordering, such as recently used emoji.
///
/// Root records every row and command run from root search here by itself, with
/// ``LaunchSource/root``. A feature records uses that happen in its own pages, usually with
/// ``Action/recordingUse()``. Uses are stored locally and erased with the rest of learning. Every
/// method is an in-memory lookup, cheap enough for `actions(for:)` and a list load.
public protocol UsageService: Sendable {
    /// Records one use of an item now. With a snapshot, ``recentlyUsed(namespace:limit:)`` can hand
    /// the row back without the feature looking it up.
    func recordUse(of id: ItemID, snapshot: Row?)

    /// Items in a namespace, most recently used first.
    func recentlyUsed(namespace: String, limit: Int) -> [UsageRecord]

    /// How many uses are recorded for an item.
    func useCount(of id: ItemID) -> Int

    /// A score per item in a namespace that mixes frequency and recency: each use counts 1, halved
    /// for every 7 days since. Only the order is meaningful. Items never used are absent.
    func frecency(namespace: String) -> [ItemID: Double]

    /// Forgets an item: its uses, and the row root search remembered for it. Call it when the item is
    /// gone, such as a file moved to the Trash.
    func forget(_ id: ItemID)

    /// Forgets every item in a namespace, for "Clear Recently Used".
    func forgetAll(namespace: String)
}

extension UsageService {
    /// Records one use of an item now, without a snapshot.
    public func recordUse(of id: ItemID) {
        recordUse(of: id, snapshot: nil)
    }

    /// Records one use of a row now, keeping a snapshot unless the row's ``Row/memory`` says not to.
    public func recordUse(of row: Row) {
        recordUse(of: row.id, snapshot: row.memory == .remember ? row : nil)
    }
}

/// One item's recorded use.
public struct UsageRecord: Hashable, Sendable {
    public var id: ItemID
    /// The row as it was last recorded, when a snapshot was kept.
    public var snapshot: Row?
    public var lastUsed: Date
    public var count: Int

    public init(id: ItemID, snapshot: Row?, lastUsed: Date, count: Int) {
        self.id = id
        self.snapshot = snapshot
        self.lastUsed = lastUsed
        self.count = count
    }
}
