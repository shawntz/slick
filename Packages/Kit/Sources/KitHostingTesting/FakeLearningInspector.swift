import Foundation
import Kit
import KitHosting
import KitTesting

/// What was learned, in memory, for SettingsUI tests.
///
/// Set ``items``, ``learnedQueries`` and ``learnedTriggers``; the summary is computed from them.
/// Pause is stored in ``HostSettings/learningPaused`` on the settings service it is given, as the
/// contract asks.
@MainActor public final class FakeLearningInspector: LearningInspector {
    public let changes = ChangeSignal()
    /// Every learned item. ``topItems(limit:)`` orders them by use count.
    public var items: [LearnedItem]
    /// Every learned query.
    public var learnedQueries: [LearnedQuery]
    /// Every suggestion trigger, in the order ``triggers()`` lists them.
    public var learnedTriggers: [LearnedTrigger]
    /// When set, ``eraseAll()`` throws it and erases nothing.
    public var eraseFailure: (any Error)?

    /// Items passed to ``forget(item:)``, in order.
    public private(set) var forgottenItems: [ItemID] = []
    /// Queries passed to ``forget(query:)``, in order.
    public private(set) var forgottenQueries: [String] = []
    /// How many times ``eraseAll()`` erased.
    public private(set) var eraseCount = 0
    /// Triggers passed to ``resetTrigger(featureID:triggerID:)``, as `<feature id>.<trigger id>`, in
    /// order.
    public private(set) var resetTriggers: [String] = []

    private let settings: FeatureSettings

    /// - Parameter settings: Where pause is stored. Defaults to a private ``FakeSettings``.
    public init(
        items: [LearnedItem] = [], queries: [LearnedQuery] = [], triggers: [LearnedTrigger] = [],
        settings: (any SettingsService)? = nil
    ) {
        self.items = items
        self.learnedQueries = queries
        self.learnedTriggers = triggers
        self.settings = HostSettings.settings(settings ?? FakeSettings())
    }

    public var isPaused: Bool { settings[HostSettings.learningPaused] }

    public func setPaused(_ paused: Bool) {
        settings[HostSettings.learningPaused] = paused
        changes.send()
    }

    /// Events are the sum of use counts, the first event is the oldest last use, and each event
    /// takes 32 bytes, the size of one log record.
    public func summary() async -> LearningSummary {
        let events = items.reduce(0) { $0 + $1.useCount }
        return LearningSummary(
            eventCount: events, itemCount: items.count, queryCount: learnedQueries.count,
            firstEvent: items.compactMap(\.lastUsed).min(), bytesOnDisk: Int64(events) * 32)
    }

    public func topItems(limit: Int) async -> [LearnedItem] {
        let sorted = items.sorted { $0.useCount != $1.useCount ? $0.useCount > $1.useCount : $0.title < $1.title }
        return Array(sorted.prefix(max(limit, 0)))
    }

    public func queries(matching text: String, limit: Int) async -> [LearnedQuery] {
        let matching = learnedQueries.filter {
            text.isEmpty || $0.query.range(of: text, options: .caseInsensitive) != nil
        }
        let sorted = matching.sorted { ($0.items.first?.weight ?? 0) > ($1.items.first?.weight ?? 0) }
        return Array(sorted.prefix(max(limit, 0)))
    }

    public func forget(item id: ItemID) async {
        forgottenItems.append(id)
        items.removeAll { $0.id == id }
        for index in learnedQueries.indices {
            learnedQueries[index].items.removeAll { $0.id == id }
        }
        learnedQueries.removeAll { $0.items.isEmpty }
        changes.send()
    }

    public func forget(query: String) async {
        forgottenQueries.append(query)
        learnedQueries.removeAll { $0.query == query }
        changes.send()
    }

    public func eraseAll() async throws {
        if let eraseFailure { throw eraseFailure }
        eraseCount += 1
        items = []
        learnedQueries = []
        learnedTriggers = learnedTriggers.map(Self.fresh)
        changes.send()
    }

    public func triggers() async -> [LearnedTrigger] {
        learnedTriggers
    }

    /// Switches the trigger back on with no impressions, as Root does.
    public func resetTrigger(featureID: String, triggerID: String) async {
        resetTriggers.append(featureID + "." + triggerID)
        learnedTriggers = learnedTriggers.map { trigger in
            trigger.featureID == featureID && trigger.triggerID == triggerID ? Self.fresh(trigger) : trigger
        }
        changes.send()
    }

    private static func fresh(_ trigger: LearnedTrigger) -> LearnedTrigger {
        var fresh = trigger
        fresh.impressions = 0
        fresh.taken = 0
        fresh.isOff = false
        return fresh
    }
}
