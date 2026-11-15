import Foundation
import Kit

extension FeatureHarness {
    /// Every catalog row the feature adds to root search, without rows that have expired.
    public func catalogRows() async throws -> [Row] {
        let now = fakes.clock.now
        var rows: [Row] = []
        for source in feature.catalogSources {
            rows += try await source.rows().filter { ($0.expires ?? .distantFuture) > now }
        }
        return rows
    }

    /// The instant providers' answers for a root query.
    public func instantAnswers(for query: String) -> [InstantAnswer] {
        feature.liveProviders.compactMap { provider in
            guard case .instant(let instant) = provider else { return nil }
            return instant.answer(for: query)
        }
    }

    /// The async providers' sections for a root query, as root would fill them: providers that take
    /// the query over win alone and are not limited; others need the minimum length and are cut to
    /// their maximum rows. Sections are titled for the query.
    public func asyncSections(for query: String) async throws -> [ListSection] {
        let providers = feature.liveProviders.compactMap { provider -> (any AsyncProvider)? in
            guard case .async(let async) = provider else { return nil }
            return async
        }
        let takeovers = providers.filter { $0.takesOver(query) }
        var sections: [ListSection] = []
        for provider in takeovers.isEmpty ? providers : takeovers {
            guard !takeovers.isEmpty || query.count >= provider.minimumQueryLength else { continue }
            let rows = try await provider.results(for: query)
            let shown = takeovers.isEmpty ? Array(rows.prefix(provider.maximumRows)) : rows
            if !shown.isEmpty {
                sections.append(ListSection(provider.sectionTitle(for: query), id: provider.namespace, rows: shown))
            }
        }
        return sections
    }

    /// The suggestions root could show at a moment: triggers missing a permission are skipped and
    /// expired suggestions dropped, as root does before sampling.
    public func suggestions(at date: Date? = nil) async throws -> [Suggestion] {
        let now = date ?? fakes.clock.now
        var result: [Suggestion] = []
        for trigger in feature.suggestionTriggers
        where trigger.requires.allSatisfy({ fakes.permissions.status(of: $0).isGranted }) {
            result += try await trigger.suggestions(at: now).filter { $0.expires > now }
        }
        return result
    }

    /// The actions root would offer for one of the feature's rows: a command, catalog, live provider
    /// or suggestion row, including one rebuilt from a snapshot after a relaunch. Root finds the
    /// owner by the row's namespace, as here.
    public func rootActions(for row: Row) -> [Action] {
        let namespace = row.id.namespace
        if namespace == ItemID.ReservedNamespace.command {
            let command = feature.commands.first { $0.itemID(feature: F.manifest.id) == row.id }
            return shown(command?.rowActions?() ?? [])
        }
        let owner: (any RowActionProvider)? =
            feature.catalogSources.first { $0.namespace == namespace }
            ?? feature.liveProviders.first { $0.namespace == namespace }?.actionProvider
            ?? feature.suggestionTriggers.first { $0.namespace == namespace }
        return shown(owner?.actions(for: row) ?? [])
    }

    /// Runs one of a root row's actions by ID or title, with the root query.
    @discardableResult
    public func performRoot(_ actionID: String, on row: Row, query: String = "") async throws -> ActionOutcome {
        try await perform(try action(actionID, in: rootActions(for: row)), row: row, query: query, launch: .root)
    }

    /// The universal actions the feature offers for a selection.
    public func universalActions(for selection: Selection) -> [Action] {
        shown(feature.universalActions.filter { $0.accepts.contains(selection.kind) }.flatMap { $0.actions(selection) })
    }

    /// The universal actions the feature offers for what a row stands for (``Row/represents``), as
    /// the host appends them to the row's action panel.
    public func universalActions(for row: Row) -> [Action] {
        row.represents.map(universalActions(for:)) ?? []
    }

    /// Runs one universal action by ID or title. The query is the selection as text.
    @discardableResult
    public func performUniversal(_ actionID: String, on selection: Selection) async throws -> ActionOutcome {
        try await perform(
            try action(actionID, in: universalActions(for: selection)), row: nil, query: selection.text,
            launch: .selection)
    }
}
