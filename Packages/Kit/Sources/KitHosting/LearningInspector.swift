import Foundation
import Kit

/// What the engine learned, for the learning inspector in settings, with forget, pause and erase.
///
/// Root implements it over the engine. SettingsUI shows it. Learning never leaves the machine; this
/// is how the user sees and removes it. The async members read or write the engine off the main
/// thread and may take a while on a large history.
@MainActor public protocol LearningInspector: AnyObject, Sendable {
    /// Sent after anything learned changed: a new run, a forget, an erase, or pause turned on or off.
    var changes: ChangeSignal { get }

    /// True while learning is paused: runs are not recorded, and what was learned still ranks.
    var isPaused: Bool { get }

    /// Pauses or resumes learning. Stored in ``HostSettings/learningPaused``.
    func setPaused(_ paused: Bool)

    /// Counts and size of everything learned.
    func summary() async -> LearningSummary

    /// The most used items, most used first.
    func topItems(limit: Int) async -> [LearnedItem]

    /// Learned queries that contain `text`, ignoring case, strongest first. Empty text lists every
    /// query.
    func queries(matching text: String, limit: Int) async -> [LearnedQuery]

    /// Forgets one item everywhere: its uses, its query affinity and its remembered row.
    func forget(item id: ItemID) async

    /// Forgets one learned query, so typing it ranks by text again.
    func forget(query: String) async

    /// Erases everything learned: the event log, the snapshot and every remembered row.
    func eraseAll() async throws

    /// What was learned about each suggestion trigger of the features that are on, in feature
    /// order, including the triggers that switched themselves off. Default empty.
    func triggers() async -> [LearnedTrigger]

    /// Switches a suggestion trigger back on and forgets what was learned about it, so it starts
    /// again from its prior. Default does nothing.
    func resetTrigger(featureID: String, triggerID: String) async
}

extension LearningInspector {
    public func triggers() async -> [LearnedTrigger] { [] }
    public func resetTrigger(featureID: String, triggerID: String) async {}
}

/// Counts and size of what the engine learned.
public struct LearningSummary: Hashable, Sendable {
    /// Recorded runs in the event log.
    public var eventCount: Int
    /// Distinct items with at least one recorded run.
    public var itemCount: Int
    /// Distinct learned queries.
    public var queryCount: Int
    /// When the oldest recorded event happened. Nil when nothing is recorded.
    public var firstEvent: Date?
    /// Bytes the event log and snapshot take on disk.
    public var bytesOnDisk: Int64

    public init(eventCount: Int, itemCount: Int, queryCount: Int, firstEvent: Date?, bytesOnDisk: Int64) {
        self.eventCount = eventCount
        self.itemCount = itemCount
        self.queryCount = queryCount
        self.firstEvent = firstEvent
        self.bytesOnDisk = bytesOnDisk
    }

    /// Nothing learned.
    public static let empty = LearningSummary(
        eventCount: 0, itemCount: 0, queryCount: 0, firstEvent: nil, bytesOnDisk: 0)
}

/// One item as the inspector lists it.
public struct LearnedItem: Identifiable, Hashable, Sendable {
    public var id: ItemID
    /// The title to show: from the catalog, or from the remembered row when the item is gone.
    public var title: String
    public var icon: Icon?
    public var useCount: Int
    public var lastUsed: Date?

    public init(id: ItemID, title: String, icon: Icon? = nil, useCount: Int, lastUsed: Date?) {
        self.id = id
        self.title = title
        self.icon = icon
        self.useCount = useCount
        self.lastUsed = lastUsed
    }
}

/// One learned query and the items it favors.
public struct LearnedQuery: Identifiable, Hashable, Sendable {
    /// One item a query favors, with its decayed weight.
    public struct Favored: Identifiable, Hashable, Sendable {
        public var id: ItemID
        public var title: String
        public var icon: Icon?
        /// The item's decayed weight in the query's affinity row.
        public var weight: Double
        /// True when the item holds the learned band for this query and ranks above an exact title
        /// match. The weight alone does not say so: an item needs 1.1 or more to hold the band, but
        /// the holder changes only as the ranking contract's fourth rule allows, so a stronger item
        /// can sit below the holder for a while. At most one item per query holds it.
        public var holdsBand: Bool

        public init(id: ItemID, title: String, icon: Icon? = nil, weight: Double, holdsBand: Bool = false) {
            self.id = id
            self.title = title
            self.icon = icon
            self.weight = weight
            self.holdsBand = holdsBand
        }
    }

    /// The query as the user typed it, folded.
    public var query: String
    /// Strongest first. At most 8, the size of an affinity row.
    public var items: [Favored]

    public var id: String { query }

    public init(query: String, items: [Favored]) {
        self.query = query
        self.items = items
    }
}

/// What was learned about one suggestion trigger type, such as a feature's meeting reminder.
public struct LearnedTrigger: Identifiable, Hashable, Sendable {
    /// The manifest ID of the feature that offers the trigger.
    public var featureID: String
    /// The trigger's ``SuggestionTrigger/id``, unique within the feature.
    public var triggerID: String
    /// How often the user takes its suggestions now, from 0 to 1: the trigger's prior, moved by
    /// what the user did.
    public var acceptance: Double
    /// Sessions in which one of its suggestions showed long enough to count, or was taken.
    public var impressions: Int
    /// Suggestions of this trigger the user ran.
    public var taken: Int
    /// True once acceptance stayed low and the trigger switched itself off. Root no longer asks it
    /// until it is reset.
    public var isOff: Bool

    /// `<feature id>.<trigger id>`.
    public var id: String { featureID + "." + triggerID }

    public init(featureID: String, triggerID: String, acceptance: Double, impressions: Int, taken: Int, isOff: Bool) {
        self.featureID = featureID
        self.triggerID = triggerID
        self.acceptance = acceptance
        self.impressions = impressions
        self.taken = taken
        self.isOff = isOff
    }
}
