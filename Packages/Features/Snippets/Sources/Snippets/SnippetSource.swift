import Foundation
import Kit

/// The snippets as a list page, as root search entries, and as the instant answer when the root
/// query is exactly a keyword. One object under one namespace, so a snippet keeps one ID and one
/// learning history wherever it shows.
///
/// The host filters the list: every row is handed over once, built off the main thread.
final class SnippetSource: ListSource, CatalogSource, InstantProvider {
    let namespace = SnippetIDs.namespace
    private unowned let feature: SnippetsFeature

    init(feature: SnippetsFeature) {
        self.feature = feature
    }

    var changes: ChangeSignal? { feature.library.changes }

    var reloadsOnSettings: [AnySettingKey] {
        [
            SnippetsSettings.order.erased, SnippetsSettings.keywordPrefix.erased,
            SnippetsSettings.showsInRootSearch.erased,
        ]
    }

    // MARK: List

    func load(_ request: ListRequest) async throws -> ListResult {
        await feature.library.ready()
        let settings = feature.context.settings
        let index = feature.library.index
        let sections = await SnippetRows.sections(
            index, filter: request.filter, prefix: SnippetsSettings.prefix(in: settings),
            order: settings[SnippetsSettings.order],
            usage: feature.context.usage)
        return ListResult(sections: sections, filter: SnippetRows.filter(index), notice: notice())
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let snippet = feature.library.index.snippet(id: row.id.key) else { return nil }
        return await SnippetDetail.make(
            snippet, index: feature.library.index, prefix: SnippetsSettings.prefix(in: feature.context.settings),
            uses: feature.context.usage.useCount(of: row.id))
    }

    /// Built from the row's ID alone, so a row root search kept from an earlier launch still works.
    func actions(for row: Row) -> [Action] {
        guard row.id.namespace == namespace, let snippet = feature.library.index.snippet(id: row.id.key) else {
            return []
        }
        return feature.actions.actions(for: snippet)
    }

    /// A banner when the file cannot be read, or when expansion is on but cannot run.
    private func notice() -> Notice? {
        switch feature.library.state {
        case .unreadable:
            return Notice(
                icon: .symbol("exclamationmark.triangle", tint: .orange), title: Strings.unreadableTitle,
                message: Strings.unreadableMessage(SnippetLibrary.fileName), action: feature.actions.showFile())
        case .newerVersion:
            return Notice(
                icon: .symbol("exclamationmark.triangle", tint: .orange), title: Strings.newerFileTitle,
                message: Strings.newerFileMessage)
        case .loading, .ready:
            break
        }
        if feature.context.settings[SnippetsSettings.expansionEnabled],
            case .needsPermission(let permission) = feature.expansion.status
        {
            return Notice(
                icon: .symbol("keyboard.badge.exclamationmark"), title: Strings.expansionNotice(permission),
                action: feature.actions.allow(permission))
        }
        return nil
    }

    // MARK: Root search

    func rows() async throws -> [Row] {
        await feature.library.ready()
        let settings = feature.context.settings
        guard settings[SnippetsSettings.showsInRootSearch] else { return [] }
        return await SnippetRows.catalog(
            feature.library.index, prefix: SnippetsSettings.prefix(in: settings), usage: feature.context.usage)
    }

    /// The snippet whose keyword is exactly the query, first in root search. Inside the 100 µs
    /// budget: the prefix and a set of first bytes turn almost every query away before one lookup.
    func answer(for query: String) -> InstantAnswer? {
        let index = feature.library.index
        guard !index.keywordInitials.isEmpty else { return nil }
        let settings = feature.context.settings
        let prefix = SnippetsSettings.prefix(in: settings)
        guard query.hasPrefix(prefix) else { return nil }
        let keyword = query.dropFirst(prefix.count)
        guard let first = keyword.utf8.first, index.keywordInitials.contains(first),
            let snippet = index.snippet(keyword: keyword), settings[SnippetsSettings.showsInRootSearch]
        else { return nil }
        return InstantAnswer(rows: [SnippetRows.row(snippet, prefix: prefix, rank: 0)], claimsTop: true)
    }
}
