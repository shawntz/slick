import Foundation
import Kit

/// The Search Bookmarks page: every bookmark of the chosen browsers in one section, filtered by the
/// host as the user types, with a dropdown for one browser, one profile or the Reading List.
///
/// The rows are built once per load, off the main thread, so opening the page only hands them
/// over. A notice says what is missing: a browser to choose, Full Disk Access for Safari, or a file
/// that could not be read.
final class BookmarkList: ListSource {
    private let library: BookmarkLibrary
    private let builder: BookmarkActions
    private let context: FeatureContext
    /// Makes the action that pushes the form for choosing browsers. Set by the feature.
    var chooseBrowsers: (@MainActor () -> Action)?

    init(library: BookmarkLibrary, builder: BookmarkActions, context: FeatureContext) {
        self.library = library
        self.builder = builder
        self.context = context
    }

    var changes: ChangeSignal? { library.changes }

    /// The page as a command opens it, with the dropdown for what is loaded now.
    func page(initialQuery: String = "") -> ListPage {
        ListPage(
            self, searchPlaceholder: Strings.List.placeholder,
            filter: BookmarkFilter.dropdown(for: library.snapshot.profiles), showsDetail: true,
            emptyState: emptyState, initialQuery: initialQuery)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        await library.ready()
        try Task.checkCancellation()
        let snapshot = library.snapshot
        let rows = await Self.rows(of: snapshot, filter: BookmarkFilter(optionID: request.filter))
        try Task.checkCancellation()
        return ListResult(
            sections: [ListSection(Strings.List.section, id: "bookmarks", showsCount: true, rows: rows)],
            emptyState: emptyState, filter: BookmarkFilter.dropdown(for: snapshot.profiles), notice: notice)
    }

    /// The rows a filter shows, picked off the main thread: 50,000 rows take a moment to scan.
    @concurrent nonisolated static func rows(of snapshot: BookmarkSnapshot, filter: BookmarkFilter) async -> [Row] {
        snapshot.rows(matching: filter)
    }

    func actions(for row: Row) -> [Action] {
        let actions = builder.actions(for: row)
        guard !actions.isEmpty else { return [] }
        return actions + [reloadAction]
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let bookmark = library.snapshot.bookmark(key: row.id.key) else { return nil }
        var metadata: [MetadataItem] = [
            .label(Strings.Detail.title, value: bookmark.title),
            .label(Strings.Detail.link, value: LinkText.oneLine(bookmark.link, limit: 2_000)),
            .label(Strings.Detail.folder, value: BookmarkIndex.subtitle(bookmark.folders)),
            .label(
                Strings.Detail.browser, value: bookmark.browser.name, icon: .app(bundleID: bookmark.browser.bundleID)),
        ]
        if library.snapshot.profiles.filter({ $0.browser == bookmark.browser }).count > 1 {
            metadata.append(.label(Strings.Detail.profile, value: bookmark.profileName))
        }
        if let date = bookmark.dateAdded { metadata.append(.date(Strings.Detail.added, date)) }
        if let tag = Strings.kindTag(bookmark.kind, link: bookmark.link) {
            metadata.append(.label(Strings.Detail.kind, value: tag))
        }
        return Detail(nil, metadata: metadata)
    }

    // MARK: - What the page says

    private var reloadAction: Action {
        Action(
            Strings.Actions.reload, id: "reload", icon: .symbol("arrow.clockwise"), shortcut: .refresh,
            runPolicy: .dropWhileRunning
        ) { [library] context in
            await library.reload(force: true).value
            context.showToast(.success(Strings.Actions.reloaded))
            return .keepOpen
        }
    }

    private var emptyState: EmptyState {
        if library.chosenBrowsers.isEmpty {
            return EmptyState(
                icon: .symbol("bookmark"), title: Strings.List.noBrowsersTitle, message: Strings.List.noBrowsersMessage,
                actions: chooseActions)
        }
        return EmptyState(
            icon: .symbol("bookmark"), title: Strings.List.emptyTitle, message: Strings.List.emptyMessage,
            actions: chooseActions)
    }

    private var chooseActions: [Action] {
        chooseBrowsers.map { [$0()] } ?? []
    }

    /// What is missing, most important first.
    private var notice: Notice? {
        if library.chosenBrowsers.isEmpty {
            return Notice(
                icon: .symbol("bookmark"), title: Strings.Notices.chooseTitle,
                message: Strings.Notices.chooseMessage(found: foundBrowsers), action: chooseBrowsers?())
        }
        if library.safariNeedsAccess {
            return Notice(
                icon: .symbol("lock"), title: Strings.Notices.safariAccessTitle,
                message: Strings.Notices.safariAccessMessage,
                action: Action(Strings.Notices.grantAccess, id: "grant-access", requires: [.fullDiskAccess]) {
                    [library] _ in
                    await library.ready()
                    return .keepOpen
                })
        }
        if !library.problems.isEmpty {
            return Notice(
                icon: .symbol("exclamationmark.triangle"), title: Strings.Notices.problemsTitle,
                message: Strings.Notices.problemsMessage(library.problems), action: reloadAction)
        }
        return nil
    }

    /// The supported browsers installed on this Mac. Asks the workspace's app catalog, which never
    /// reads the disk on this thread, and reads none of the browsers' files.
    var foundBrowsers: [Browser] {
        Browser.allCases.filter { context.workspace.application(bundleID: $0.bundleID) != nil }
    }
}

/// Bookmarks as root search entries, behind a setting that is off at first.
final class BookmarkCatalog: CatalogSource {
    let namespace = BookmarkIndex.namespace
    private let library: BookmarkLibrary
    private let builder: BookmarkActions
    private let settings: FeatureSettings

    init(library: BookmarkLibrary, builder: BookmarkActions, settings: FeatureSettings) {
        self.library = library
        self.builder = builder
        self.settings = settings
    }

    var changes: ChangeSignal? { library.changes }
    var reloadsOnSettings: [AnySettingKey] { [BookmarkSettings.showsInRootSearch.erased] }

    func rows() async throws -> [Row] {
        guard settings[BookmarkSettings.showsInRootSearch] else { return [] }
        await library.ready()
        return library.snapshot.catalogRows
    }

    func actions(for row: Row) -> [Action] {
        builder.actions(for: row)
    }
}
