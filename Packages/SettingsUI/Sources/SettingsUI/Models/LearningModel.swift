import Foundation
import Kit
import KitHosting
import Observation

/// The learning pane: what root search learned from the user's choices, with pause, forget and
/// erase, which item holds first place for each query, and the suggestions that switched
/// themselves off. Everything it shows lives on this Mac.
@Observable final class LearningModel {
    static let topItemLimit = 12
    static let queryLimit = 200

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()

    private(set) var summary = LearningSummary.empty
    private(set) var topItems: [LearnedItem] = []
    private(set) var queries: [LearnedQuery] = []
    /// Every suggestion trigger of the features that are on, with what was learned about it.
    private(set) var triggers: [LearnedTrigger] = []
    private(set) var isLoading = false
    /// Filters the learned queries.
    var filter = "" {
        didSet { if filter != oldValue { Task { await loadQueries() } } }
    }

    init(context: SettingsContext) {
        self.context = context
        tasks.follow(context.dependencies.learning.changes, bumping: revision)
    }

    private var learning: any LearningInspector { context.dependencies.learning }

    /// Changes to what was learned, for the view to reload on.
    var changeCount: Int {
        revision.track()
        return revision.value
    }

    /// Loads the summary, the top items and the queries.
    func load() async {
        isLoading = true
        summary = await learning.summary()
        topItems = await learning.topItems(limit: Self.topItemLimit)
        await loadQueries()
        triggers = await learning.triggers()
        isLoading = false
    }

    private func loadQueries() async {
        queries = await learning.queries(matching: filter.trimmingCharacters(in: .whitespaces), limit: Self.queryLimit)
    }

    var isPaused: Bool {
        get {
            revision.track()
            return learning.isPaused
        }
        set {
            learning.setPaused(newValue)
            revision.bump()
        }
    }

    /// Forgets what one typed query learned.
    func forget(query: String) async {
        await learning.forget(query: query)
        await load()
    }

    /// Forgets one item everywhere.
    func forget(item id: ItemID) async {
        await learning.forget(item: id)
        await load()
    }

    /// The suggestion triggers that switched themselves off because their suggestions were rarely
    /// taken.
    var switchedOffTriggers: [LearnedTrigger] {
        triggers.filter(\.isOff)
    }

    /// Switches a trigger back on, with what it learned forgotten.
    func turnOn(_ trigger: LearnedTrigger) async {
        await learning.resetTrigger(featureID: trigger.featureID, triggerID: trigger.triggerID)
        context.toasts.show(.success("Suggestions from \(featureName(of: trigger)) are back on"))
        await load()
    }

    /// The name of the feature that offers a trigger, or its ID when it is not registered.
    func featureName(of trigger: LearnedTrigger) -> String {
        context.directory.feature(trigger.featureID)?.manifest.name ?? trigger.featureID
    }

    /// What a trigger suggests, from its ID: "meeting-soon" reads "Meeting soon".
    func triggerTitle(_ trigger: LearnedTrigger) -> String {
        let words = trigger.triggerID.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).joined(
            separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// How a switched-off trigger did, such as "Taken 1 of 24 times".
    func triggerDetail(_ trigger: LearnedTrigger) -> String {
        "Taken \(trigger.taken) of \(trigger.impressions) times"
    }

    /// The item that ranks first for a query, above an exact name match, if any.
    func bandHolder(of query: LearnedQuery) -> LearnedQuery.Favored? {
        query.items.first(where: \.holdsBand)
    }

    /// Erases everything learned, after the user confirms.
    func eraseAll() async {
        let confirmed = await context.confirmations.ask(
            Confirmation(
                "Erase everything learned?",
                message:
                    "Root search forgets every choice and ranks by text alone until it learns again. This cannot be undone.",
                confirmTitle: "Erase", isDestructive: true))
        guard confirmed else { return }
        do {
            try await learning.eraseAll()
            context.toasts.show(.success("Erased everything learned"))
        } catch {
            context.toasts.show(error, title: "Could not erase")
        }
        await load()
    }

    // MARK: Text

    var summaryText: String {
        guard summary.eventCount > 0 else { return "Nothing learned yet." }
        let runs = summary.eventCount == 1 ? "1 run" : "\(summary.eventCount) runs"
        let items = summary.itemCount == 1 ? "1 item" : "\(summary.itemCount) items"
        let queries = summary.queryCount == 1 ? "1 query" : "\(summary.queryCount) queries"
        return "\(runs) of \(items), \(queries)."
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: summary.bytesOnDisk, countStyle: .file)
    }

    var sinceText: String? {
        summary.firstEvent.map { "Learning since " + $0.formatted(date: .abbreviated, time: .omitted) + "." }
    }

    /// The icon of a learned item, its own or the one the catalog knows.
    func icon(for item: LearnedItem) -> Icon? {
        item.icon ?? context.icon(for: item.id)
    }
}
