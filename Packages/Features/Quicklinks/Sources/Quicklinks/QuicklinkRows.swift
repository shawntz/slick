import Foundation
import Kit
import KitTemplates

/// Rows, icons and commands for quicklinks. Rows hold data only: their actions come from
/// ``QuicklinkActions``, looked up by the row's key. `nonisolated`, so rows are built off the main
/// thread.
nonisolated enum QuicklinkRows {
    /// The namespace of quicklink rows: `quicklink:<id>`.
    static let namespace = "quicklink"

    /// The quicklink's own symbol, else the site's favicon, else the app that opens it, else a link.
    /// The host resolves a favicon from its cache or draws a globe; this feature never fetches one.
    static func icon(quicklink: Quicklink, webHost: String?) -> Icon {
        if let symbol = quicklink.icon, !symbol.isEmpty { return .symbol(symbol) }
        if let host = webHost { return .favicon(domain: host) }
        if let app = quicklink.openWith, !app.isEmpty { return .app(bundleID: app) }
        return .symbol("link")
    }

    /// A host without its `www.`, for subtitles and keywords.
    static func siteName(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A quicklink without arguments in root search.
    static func catalogRow(_ entry: QuicklinkEntry) -> Row {
        Row(
            id: ItemID(namespace, entry.id), title: entry.quicklink.name, subtitle: entry.displayText,
            icon: entry.icon, keywords: entry.searchKeywords, memory: .learnOnly)
    }

    /// The catalog's rows, built off the main thread.
    @concurrent static func catalogRows(_ entries: [QuicklinkEntry]) async -> [Row] {
        entries.filter { $0.isEnabled && $0.arguments.isEmpty }.map(catalogRow)
    }

    /// A quicklink on the Search Quicklinks page, with its first keyword and its state.
    static func listRow(_ entry: QuicklinkEntry, isDefaultEngine: Bool, offersFallback: Bool) -> Row {
        var accessories: [Accessory] = []
        if let keyword = entry.quicklink.keywords.first { accessories.append(.text(keyword)) }
        if isDefaultEngine {
            accessories.append(.tag(Strings.defaultTag))
        } else if offersFallback {
            accessories.append(.icon(.symbol("arrow.turn.down.right"), tooltip: Strings.fallbackTooltip))
        }
        if !entry.quicklink.isEnabled { accessories.append(.tag(Strings.offTag)) }
        return Row(
            id: ItemID(namespace, entry.id), title: entry.quicklink.name, subtitle: entry.displayText,
            icon: entry.icon, accessories: accessories, keywords: entry.searchKeywords,
            rankHint: entry.quicklink.isEnabled ? 0 : -1, memory: .learnOnly)
    }

    /// The Search Quicklinks sections for one filter value, sorted by name, built off the main
    /// thread.
    @concurrent static func listSections(
        _ entries: [QuicklinkEntry], filter: String?, engineID: String?, fallbacksOn: Bool
    ) async -> [ListSection] {
        let shown = entries.filter { entry in
            switch filter {
            case "own": !entry.quicklink.isBuiltIn
            case "builtin": entry.quicklink.isBuiltIn
            case "off": !entry.quicklink.isEnabled
            default: true
            }
        }
        .sorted { $0.quicklink.name.localizedStandardCompare($1.quicklink.name) == .orderedAscending }
        func rows(_ entries: [QuicklinkEntry]) -> [Row] {
            entries.map { entry in
                listRow(
                    entry, isDefaultEngine: entry.id == engineID,
                    offersFallback: entry.offersFallback(engineID: engineID, fallbacksOn: fallbacksOn))
            }
        }
        return [
            ListSection(Strings.ownSection, id: "own", rows: rows(shown.filter { !$0.quicklink.isBuiltIn })),
            ListSection(Strings.builtInSection, id: "builtin", rows: rows(shown.filter(\.quicklink.isBuiltIn))),
        ]
    }
}

/// A quicklink with arguments as a root search command: its arguments become fields in the search
/// bar, and its row offers the quicklink's other actions after Run.
enum QuicklinkCommand {
    static func make(_ entry: QuicklinkEntry, offersFallback: Bool, feature: QuicklinksFeature) -> Command {
        let id = entry.id
        let name = entry.quicklink.name
        return Command(
            id: entry.quicklink.commandID, title: name,
            subtitle: entry.template.webHost.map(QuicklinkRows.siteName) ?? Strings.featureName,
            icon: entry.icon, keywords: entry.quicklink.keywords,
            arguments: entry.commandArguments, requires: entry.requires,
            fallback: offersFallback ? Fallback(startsOn: true) { Strings.fallbackTitle(name, $0) } : nil
        ) { [unowned feature] context in
            // Read the quicklink again: the host may hold this command for a moment after a change.
            guard let current = feature.entry(id: id) else { throw ActionFailure(Strings.quicklinkGone) }
            return try await feature.open(current, context: context)
        }
        .withRowActions { [unowned feature] in
            feature.entry(id: id).map { feature.actions.rowActions(for: $0, on: .commandRow) } ?? []
        }
    }
}

/// Quicklinks without arguments, in root search's catalog. Quicklinks with arguments are commands.
final class QuicklinkCatalog: CatalogSource {
    private unowned let feature: QuicklinksFeature

    init(feature: QuicklinksFeature) {
        self.feature = feature
    }

    let namespace = QuicklinkRows.namespace
    var changes: ChangeSignal? { feature.changes }

    func rows() async throws -> [Row] {
        await QuicklinkRows.catalogRows(feature.entries)
    }

    /// Works from the row's key alone, so a row root hands back after a relaunch still has actions.
    func actions(for row: Row) -> [Action] {
        guard let entry = feature.entry(id: row.id.key) else { return [] }
        return feature.actions.rowActions(for: entry, on: .catalog)
    }
}

/// The Search Quicklinks page, and the page Edit Quicklink shows to pick one.
final class QuicklinkList: ListSource {
    enum Purpose {
        /// Every quicklink with a detail pane. Return opens.
        case browse
        /// Every quicklink. Return edits.
        case edit
    }

    private unowned let feature: QuicklinksFeature
    let purpose: Purpose

    init(feature: QuicklinksFeature, purpose: Purpose) {
        self.feature = feature
        self.purpose = purpose
    }

    var changes: ChangeSignal? { feature.changes }

    static let filter = FilterDropdown(
        title: Strings.filterTitle,
        options: [
            FilterOption(id: "all", title: Strings.filterAll),
            FilterOption(id: "own", title: Strings.filterOwn),
            FilterOption(id: "builtin", title: Strings.filterBuiltIn),
            FilterOption(id: "off", title: Strings.filterOff),
        ])

    func page(initialQuery: String = "") -> ListPage {
        ListPage(
            self, searchPlaceholder: purpose == .browse ? Strings.searchPlaceholder : Strings.editPlaceholder,
            filter: Self.filter, showsDetail: purpose == .browse,
            emptyState: EmptyState(
                icon: .symbol("link"), title: Strings.emptyTitle, message: Strings.emptyMessage,
                actions: [feature.actions.createAction]),
            initialQuery: initialQuery)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let sections = await QuicklinkRows.listSections(
            feature.entries, filter: request.filter, engineID: feature.defaultEngine?.id,
            fallbacksOn: feature.context.settings[QuicklinksSettings.offersFallbacks])
        return ListResult(sections: sections)
    }

    func detail(for row: Row) async throws -> Detail? {
        guard purpose == .browse, let entry = feature.entry(id: row.id.key) else { return nil }
        let quicklink = entry.quicklink
        var metadata: [MetadataItem] = []
        if !quicklink.keywords.isEmpty {
            metadata.append(.tags(Strings.detailKeywords, quicklink.keywords.map { Tag($0) }))
        }
        if let app = quicklink.openWith, !app.isEmpty {
            let name = feature.context.workspace.application(bundleID: app)?.name ?? app
            metadata.append(.label(Strings.detailOpensWith, value: name, icon: .app(bundleID: app)))
        } else {
            metadata.append(.label(Strings.detailOpensWith, value: Strings.detailDefaultApp))
        }
        let arguments = entry.arguments.map { Tag($0.name ?? Strings.argumentFallbackName) }
        if !arguments.isEmpty { metadata.append(.tags(Strings.detailArguments, arguments)) }
        if entry.takesQuery {
            let isOffered = feature.offersFallback(entry, engineID: feature.defaultEngine?.id)
            let offered = isOffered ? Strings.detailFallbackOn : Strings.detailFallbackOff
            metadata.append(.label(Strings.detailFallback, value: offered))
        }
        metadata.append(.label(Strings.detailStatus, value: quicklink.isEnabled ? Strings.detailOn : Strings.detailOff))
        return Detail(.text(quicklink.link, monospaced: true), metadata: metadata)
    }

    func actions(for row: Row) -> [Action] {
        guard let entry = feature.entry(id: row.id.key) else { return [] }
        return feature.actions.rowActions(for: entry, on: purpose == .browse ? .list : .editPicker)
    }
}
