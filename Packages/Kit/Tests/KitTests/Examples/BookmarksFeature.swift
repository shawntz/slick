import Foundation
import Kit
import KitStorage
import KitTemplates
import os

/// Example 3 of docs/FEATURES.md: a full feature. User-created bookmarks saved as JSON, a creation
/// form, a list with sections and a filter, root search entries, commands with inline arguments and
/// row actions, a fallback, a universal action, a permission for one action, and a settings pane.
final class BookmarksFeature: Feature {
    static let manifest = FeatureManifest(
        id: "bookmarks", name: "Bookmarks", icon: .symbol("bookmark"),
        summary: "Save links and open them from the search bar.",
        permissions: [PermissionNeed(.accessibility, reason: "Paste a bookmark's link into the frontmost app.")])

    let context: FeatureContext
    let changes = ChangeSignal()
    private(set) var bookmarks: [Bookmark] = []
    private let store: JSONFileStore<[Bookmark]>
    private lazy var list = BookmarkList(feature: self)

    init(context: FeatureContext) {
        self.context = context
        // A path only: the store creates the folder when it first saves.
        store = JSONFileStore(url: context.storage.dataFile("bookmarks.json"))
    }

    func activate() async {
        do {
            bookmarks = try await store.load(default: [])
        } catch {
            context.log.error("Could not read bookmarks: \(error.localizedDescription, privacy: .public)")
        }
        changes.send()
    }

    var commands: [Command] {
        let search = Command(
            id: "search", title: "Search Bookmarks", icon: Self.manifest.icon,
            arguments: [CommandArgument("query", placeholder: "Name", isOptional: true)],
            fallback: Fallback { "Search Bookmarks for \"\($0)\"" }
        ) { context in
            let filter = FilterDropdown(
                title: "Show",
                options: [FilterOption(id: "all", title: "All"), FilterOption(id: "pinned", title: "Pinned")])
            return .push(
                .list(
                    ListPage(
                        self.list, searchPlaceholder: "Search bookmarks", filter: filter, showsDetail: true,
                        emptyState: EmptyState(title: "No Bookmarks", actions: [self.addAction]),
                        initialQuery: context.arguments["query"] ?? "")))
        }
        let add = Command(id: "add", title: "Add Bookmark", icon: .symbol("plus")) { _ in .push(.form(self.form())) }
        // A bookmark whose link has {argument} placeholders becomes a command, so its arguments show
        // as fields in the search bar.
        return [search, add] + bookmarks.filter { !Template($0.link).arguments.isEmpty }.map(openCommand)
    }

    var declarationChanges: ChangeSignal? { changes }

    var catalogSources: [any CatalogSource] { [list] }

    var universalActions: [UniversalActionProvider] {
        [
            .url { url in
                [
                    Action("Save as Bookmark", id: "save-bookmark", icon: .symbol("bookmark")) { _ in
                        let link = url.absoluteString
                        try await self.add(Bookmark(name: link, link: link, created: self.context.clock.now))
                        return .close(hud: "Saved Bookmark")
                    }
                ]
            }
        ]
    }

    var settingsPane: SettingsPane? {
        SettingsPane(items: [
            .toggle("Show pinned bookmarks first", key: BookmarkSettings.pinnedFirst),
            .picker("Sort by", key: BookmarkSettings.order) { $0.title },
        ])
    }

    var addAction: Action {
        .push("Add Bookmark", icon: .symbol("plus"), shortcut: .new) { .form(self.form()) }
    }

    func bookmark(id: String) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    func add(_ bookmark: Bookmark) async throws {
        try await save(bookmarks + [bookmark])
    }

    func remove(id: String) async throws {
        try await save(bookmarks.filter { $0.id != id })
    }

    func togglePin(id: String) async throws {
        try await save(bookmarks.map { $0.id == id ? $0.with(isPinned: !$0.isPinned) : $0 })
    }

    private func save(_ updated: [Bookmark]) async throws {
        try await store.save(updated)
        bookmarks = updated
        changes.send()
    }

    private func form() -> FormPage {
        FormPage(
            title: "Add Bookmark",
            fields: [
                .text("name", title: "Name", isRequired: true),
                .text(
                    "link", title: "Link", placeholder: "https://example.com", isRequired: true,
                    info: "Add {argument name=\"query\"} for a value typed in the search bar."),
                .checkbox("pinned", title: "Pinned", label: "Show at the top"),
            ],
            submitTitle: "Add Bookmark",
            validate: { values in
                let link = Template(values.text("link"))
                // The range lets the field select the placeholder at fault.
                if let issue = link.issues.first { return ["link": FieldError(issue.message, range: issue.range)] }
                return link.source.contains("://") ? [:] : ["link": "Enter a full link, such as https://example.com"]
            },
            submit: { values, context in
                let bookmark = Bookmark(
                    name: values.text("name"), link: values.text("link"), isPinned: values.bool("pinned"),
                    created: self.context.clock.now)
                try await self.add(bookmark)
                context.showToast(.success("Added Bookmark"))
                return .pop
            })
    }

    private func openCommand(_ bookmark: Bookmark) -> Command {
        let template = Template(bookmark.link)
        let id = "open." + bookmark.id
        return Command(id: id, title: bookmark.name, icon: .symbol("link"), arguments: template.commandArguments) {
            context in
            let environment = TemplateEnvironment(context: context.feature, arguments: context.arguments.values)
            let link = await template.render(in: environment, style: .url).text
            guard let url = URL(string: link) else {
                context.showToast(.failure("Not a valid link", message: link))
                return .keepOpen
            }
            try await context.workspace.open(url)
            return .close()
        }
        .withRowActions { [list] in [.copy(bookmark.link, title: "Copy Link")] + list.manageActions(for: bookmark) }
    }
}

/// The bookmarks as a list page and as root search entries.
final class BookmarkList: ListSource, CatalogSource {
    private unowned let feature: BookmarksFeature

    init(feature: BookmarksFeature) {
        self.feature = feature
    }

    let namespace = "bookmark"
    var changes: ChangeSignal? { feature.changes }
    /// An open list reloads when the user changes the order in settings.
    var reloadsOnSettings: [AnySettingKey] { [BookmarkSettings.order.erased, BookmarkSettings.pinnedFirst.erased] }

    func rows() async throws -> [Row] {
        feature.bookmarks.map(row)
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let settings = feature.context.settings
        var bookmarks = feature.bookmarks.filter { request.filter != "pinned" || $0.isPinned }
        switch settings[BookmarkSettings.order] {
        case .name: bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .newest: bookmarks.sort { $0.created > $1.created }
        }
        guard settings[BookmarkSettings.pinnedFirst] else { return ListResult(rows: bookmarks.map(row)) }
        return ListResult(sections: [
            ListSection("Pinned", rows: bookmarks.filter(\.isPinned).map(row)),
            ListSection("Bookmarks", rows: bookmarks.filter { !$0.isPinned }.map(row)),
        ])
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let bookmark = feature.bookmark(id: row.id.key) else { return nil }
        return Detail(
            .link(URL(string: bookmark.link) ?? URL(filePath: "/")), metadata: [.date("Added", bookmark.created)])
    }

    /// Works from the row's ID alone, so a row root remembered before a relaunch still has actions.
    func actions(for row: Row) -> [Action] {
        guard let bookmark = feature.bookmark(id: row.id.key) else { return [] }
        var actions: [Action] = []
        if Template(bookmark.link).arguments.isEmpty, let url = URL(string: bookmark.link) {
            actions.append(.open(url))
        } else {
            actions.append(
                .runCommand(
                    .command(feature: BookmarksFeature.manifest.id, command: "open." + bookmark.id), title: "Open"))
        }
        return actions + [.copy(bookmark.link, title: "Copy Link"), .paste(bookmark.link, title: "Paste Link")]
            + manageActions(for: bookmark)
    }

    /// Pin and delete: on the bookmark's row, and on its command's row in root search.
    func manageActions(for bookmark: Bookmark) -> [Action] {
        [
            Action(bookmark.isPinned ? "Unpin" : "Pin", id: "pin", icon: .symbol("pin"), shortcut: .pin) { _ in
                // The change signal reloads the page; no reload() call is needed.
                try await self.feature.togglePin(id: bookmark.id)
                return .keepOpen
            },
            Action(
                "Delete Bookmark", id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
                confirmation: Confirmation("Delete \"\(bookmark.name)\"?", confirmTitle: "Delete")
            ) { _ in
                try await self.feature.remove(id: bookmark.id)
                return .keepOpen
            },
        ]
    }

    /// The row stands for its link, so every feature's actions for links are offered on it too.
    private func row(_ bookmark: Bookmark) -> Row {
        Row(
            id: ItemID(namespace, bookmark.id), title: bookmark.name, subtitle: bookmark.link,
            icon: .symbol("bookmark"),
            accessories: bookmark.isPinned ? [.icon(.symbol("pin.fill"), tooltip: "Pinned")] : [],
            keywords: [bookmark.link], represents: URL(string: bookmark.link).map(Selection.url))
    }
}

/// One bookmark as stored. `nonisolated` so the JSON store can encode it off the main actor.
nonisolated struct Bookmark: Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var link: String
    var isPinned = false
    var created: Date

    func with(isPinned: Bool) -> Bookmark {
        var copy = self
        copy.isPinned = isPinned
        return copy
    }
}

/// The feature's settings. `nonisolated`, so code off the main actor can read them too.
nonisolated enum BookmarkSettings {
    static let pinnedFirst = SettingKey("pinnedFirst", default: true)
    static let order = SettingKey("order", default: BookmarkOrder.name)
}

/// How the bookmark list is sorted.
nonisolated enum BookmarkOrder: String, CaseIterable, SettingValue {
    case name, newest

    var title: String {
        switch self {
        case .name: "Name"
        case .newest: "Newest First"
        }
    }
}
