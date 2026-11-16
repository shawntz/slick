import Foundation
import Kit

/// A feature for the parts of root search that run later than the keystroke: two async providers,
/// a suggestion trigger, a command with a live subtitle and a command Tab may run. Tests register it
/// with `RootFixture(signals: true)`.
final class SignalsFeature: Feature {
    static let manifest = FeatureManifest(id: "signals", name: "Signals", icon: .symbol("bell"))

    let web = WebResults()
    let mail = MailResults()
    let meetings = MeetingTrigger()
    let disk = DiskStatus()

    init(context: FeatureContext) {}

    var commands: [Command] {
        let disk = disk
        return [
            Command(
                id: "disk", title: "Disk Status",
                liveSubtitle: .background(every: disk.interval, changes: disk.signal) {
                    await disk.fetch(onMainThread: isMainThread())
                }
            ) { _ in .close() },
            Command(id: "ask", title: "Ask Signals", takesRootQueryOnTab: true) { _ in .close() },
            Command(id: "plain", title: "Plain Signals") { _ in .close() },
        ]
    }

    var liveProviders: [LiveProvider] { [.async(web), .async(mail)] }
    var suggestionTriggers: [any SuggestionTrigger] { [meetings] }
}

/// An async provider with the default 60 ms debounce, three rows at most, that answers from
/// ``answers`` and records each call. ``hold`` makes calls wait until ``release()``.
final class WebResults: AsyncProvider {
    let namespace = "web"
    let sectionTitle = "Web"
    var maximumRows: Int { 3 }
    var answers: [String: [Row]] = [:]
    var failure: (any Error)?
    var hold = false
    private(set) var calls: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func results(for query: String) async throws -> [Row] {
        calls.append(query)
        if hold {
            await withCheckedContinuation { waiting.append($0) }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        return answers[query] ?? [Row(id: ItemID("web", query), title: "Web: \(query)")]
    }

    /// Lets every held call go on.
    func release() {
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume() }
    }

    var heldCount: Int { waiting.count }

    func actions(for row: Row) -> [Action] {
        [Action("Open Page") { _ in .close() }]
    }
}

/// An async provider without a debounce, whose title names the query and which takes over queries
/// that start with "@".
final class MailResults: AsyncProvider {
    let namespace = "mail"
    let sectionTitle = "Mail"
    var debounce: Duration { .zero }
    var minimumQueryLength: Int { 3 }
    private(set) var calls: [String] = []
    var rowCount = 2

    func takesOver(_ query: String) -> Bool {
        query.hasPrefix("@")
    }

    func sectionTitle(for query: String) -> String {
        "Mail matching \(query)"
    }

    func results(for query: String) async throws -> [Row] {
        calls.append(query)
        return (0..<rowCount).map { index in
            Row(
                id: ItemID("mail", "\(query)-\(index)"), title: "Mail \(index) about \(query)",
                completion: "@\(query)-\(index)")
        }
    }

    func actions(for row: Row) -> [Action] {
        [Action("Open Mail") { _ in .close() }]
    }
}

/// A suggestion trigger that needs the calendars, asks again every minute, and offers ``offered``.
final class MeetingTrigger: SuggestionTrigger {
    let id = "meeting-soon"
    let namespace = "meeting"
    var prior = AcceptancePrior(accepts: 4, rejects: 1)
    var refreshInterval: Duration? { .seconds(60) }
    var requires: [Permission] { [.calendars] }
    let signal = ChangeSignal()
    var changes: ChangeSignal? { signal }
    var offered: [Suggestion] = []
    var failure: (any Error)?
    private(set) var asks: [Date] = []

    func suggestions(at date: Date) async throws -> [Suggestion] {
        asks.append(date)
        if let failure { throw failure }
        return offered
    }

    func actions(for row: Row) -> [Action] {
        [Action("Join Meeting") { _ in .close() }]
    }

    /// A meeting row that is never remembered.
    static func meeting(_ name: String, at now: Date, urgency: Urgency = .constant(1), imminent: Bool = false)
        -> Suggestion
    {
        Suggestion(
            id: "event-\(name)",
            row: Row(id: ItemID("meeting", name), title: "Join \(name.capitalized)", memory: .never),
            urgency: urgency, expires: now.addingTimeInterval(3_600),
            imminentFrom: imminent ? now.addingTimeInterval(-60) : nil)
    }
}

/// A live subtitle that fetches off the main thread and counts its fetches, and the fetches that
/// started on the main thread.
final class DiskStatus {
    /// The signal the command hands on its next read. A test replaces it, as a rescan may.
    var signal = ChangeSignal()
    /// The interval the command asks for on its next read.
    var interval: Duration = .seconds(2)
    private(set) var fetches = 0
    private(set) var fetchesOnMainThread = 0
    var text = "Disk ok"
    var color: KitColor?

    func fetch(onMainThread: Bool) -> LiveSubtitle.Value? {
        fetches += 1
        if onMainThread { fetchesOnMainThread += 1 }
        return LiveSubtitle.Value("\(text) \(fetches)", color: color)
    }
}

/// True on the main thread. Synchronous, so a background fetch can ask before it hops.
nonisolated func isMainThread() -> Bool {
    Thread.isMainThread
}
