import Foundation
import Kit

/// Offers to paste the item just copied, for two minutes after the copy, in root search's empty
/// state. The bet is that a person who copies something and opens the launcher often wants to
/// paste it somewhere.
final class RecentCopyTrigger: SuggestionTrigger {
    /// How long after a copy the suggestion is offered.
    static let window: TimeInterval = 120
    /// Characters of the item the suggestion's title quotes.
    static let quotedLength = 60

    let id = "recent-copy"
    let namespace = HistoryRows.namespace
    /// Start modest: Root learns from how often the user takes it.
    let prior = AcceptancePrior(accepts: 1, rejects: 3)
    let changes: ChangeSignal?

    private let store: HistoryStore
    private let latest: LatestCopy
    private let builder: HistoryActions
    private let workspace: any WorkspaceService

    init(
        store: HistoryStore, latest: LatestCopy, changes: ChangeSignal, actions: HistoryActions,
        workspace: any WorkspaceService
    ) {
        self.store = store
        self.latest = latest
        self.changes = changes
        self.builder = actions
        self.workspace = workspace
    }

    func suggestions(at date: Date) async throws -> [Suggestion] {
        guard let copy = latest.value else { return [] }
        let expires = copy.date.addingTimeInterval(Self.window)
        guard copy.date <= date, date < expires else { return [] }
        guard let item = try await store.summary(copy.key) else { return [] }
        let title = HistoryRows.title(for: item)
        let quoted =
            title.count > Self.quotedLength ? title.prefix(Self.quotedLength - 1) + "\u{2026}" : Substring(title)
        let appName = item.source.flatMap { workspace.application(bundleID: $0)?.name }
        var row = HistoryRows.row(for: item, query: SearchQuery(""), appName: appName)
        row.title = Strings.Suggestion.title(String(quoted))
        row.subtitle = Strings.Suggestion.subtitle(from: appName)
        row.accessories = []
        return [
            Suggestion(
                id: "\(copy.key.hex)@\(Int(copy.date.timeIntervalSince1970))", row: row,
                urgency: .decay(since: copy.date, timeConstant: .seconds(60)), expires: expires)
        ]
    }

    func actions(for row: Row) -> [Action] {
        builder.suggestionActions(for: row)
    }
}

/// The history as other features read it, through the pasteboard service's `recentText(offset:)`
/// and so the `{clipboard offset=N}` placeholder.
nonisolated struct HistoryReader: ClipboardHistoryReader {
    let store: HistoryStore

    @concurrent func text(offset: Int) async -> String? {
        try? await store.text(offset: offset)
    }
}
