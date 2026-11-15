import Foundation
import Kit
import KitTesting
import Testing

/// The file feature's own index. The live one wraps the Rust file index; tests use a fixed list of
/// synthetic paths and never walk a disk.
nonisolated protocol FileIndex: Sendable {
    func search(_ query: String) async throws -> [URL]
    func children(of directory: URL) async throws -> [URL]
}

nonisolated struct ListedFiles: FileIndex {
    let paths: [URL]

    func search(_ query: String) async throws -> [URL] {
        paths.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    func children(of directory: URL) async throws -> [URL] {
        paths.filter { $0.deletingLastPathComponent().path == directory.path }
    }
}

/// Scenario 3, file search: an async provider that adds a Files section to root search, a dedicated
/// list with custom async filtering and a Quick Look detail, the usual file actions, a navigation
/// mode that takes over queries starting with "/" or "~", and rows root can rebuild after a relaunch.
final class FileSearchSketch: Feature, AsyncProvider {
    static let manifest = FeatureManifest(id: "files", name: "File Search", icon: .symbol("doc.text.magnifyingglass"))

    let index: any FileIndex
    let home: URL

    convenience init(context: FeatureContext) {
        self.init(index: ListedFiles(paths: []), home: URL(filePath: "/"))
    }

    init(index: any FileIndex, home: URL) {
        self.index = index
        self.home = home
    }

    let namespace = "file"
    let sectionTitle = "Files"
    var liveProviders: [LiveProvider] { [.async(self)] }

    func takesOver(_ query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~")
    }

    func results(for query: String) async throws -> [Row] {
        try Task.checkCancellation()
        guard takesOver(query) else { return try await index.search(query).map(Self.row) }
        let path = query.hasPrefix("~") ? home.path + query.dropFirst() : query
        let folder = path.hasSuffix("/") ? URL(filePath: path) : URL(filePath: path).deletingLastPathComponent()
        let prefix = path.hasSuffix("/") ? "" : URL(filePath: path).lastPathComponent
        return try await index.children(of: folder).filter { $0.lastPathComponent.hasPrefix(prefix) }.map(Self.row)
    }

    static func row(_ url: URL) -> Row {
        Row(
            id: ItemID("file", url.path), title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path,
            icon: .file(path: url.path), completion: url.hasDirectoryPath ? url.path + "/" : nil, quickLookURL: url)
    }

    /// Built from the row's ID alone: the path is the key.
    func actions(for row: Row) -> [Action] {
        let url = URL(filePath: row.id.key)
        return [
            .open(url), .openWith(url), .reveal([url]), .copyPath(url), .quickLook(url), .share([.file(url)]),
            .moveToTrash([url]),
        ]
    }

    var commands: [Command] {
        [
            Command(
                id: "search", title: "Search Files", arguments: [CommandArgument("query", isOptional: true)],
                fallback: Fallback { "Search Files for \"\($0)\"" }
            ) { context in
                .push(
                    .list(
                        ListPage(
                            FileList(feature: self), showsDetail: true, initialQuery: context.arguments["query"] ?? ""))
                )
            }
        ]
    }
}

final class FileList: ListSource {
    private unowned let feature: FileSearchSketch

    init(feature: FileSearchSketch) {
        self.feature = feature
    }

    var filtering: ListFiltering { .custom(debounce: .milliseconds(80)) }

    func load(_ request: ListRequest) async throws -> ListResult {
        try Task.checkCancellation()
        let rows = request.query.isEmpty ? [] : try await feature.results(for: request.query)
        return ListResult(
            rows: rows, emptyState: EmptyState(title: request.query.isEmpty ? "Type to search files" : "No files"))
    }

    func detail(for row: Row) async throws -> Detail? {
        Detail(.preview(URL(filePath: row.id.key)), metadata: [.label("Where", value: row.subtitle ?? "")])
    }

    func actions(for row: Row) -> [Action] {
        feature.actions(for: row)
    }
}

@Suite("Scenario: file search")
struct FileSearchSketchTests {
    private let root = URL(filePath: "/tmp/kit-example", directoryHint: .isDirectory)

    private func harness() -> FeatureHarness<FileSearchSketch> {
        let names = (1...7).map { "report-\($0).txt" } + ["notes.md"]
        let paths =
            names.map { root.appending(path: $0) } + [root.appending(path: "Reports", directoryHint: .isDirectory)]
        let harness = FeatureHarness { _ in FileSearchSketch(index: ListedFiles(paths: paths), home: root) }
        harness.fakes.workspace.applications = [AppInfo(bundleID: "com.example.editor", name: "Editor")]
        return harness
    }

    @Test func addsALimitedFilesSectionToRootSearch() async throws {
        let sections = try await harness().asyncSections(for: "report")
        #expect(sections.map(\.title) == ["Files"])
        #expect(sections.first?.rows.count == 5)
    }

    @Test func takesOverPathQueriesWithoutALimit() async throws {
        let harness = harness()
        let rows = try await harness.asyncSections(for: "~/").flatMap(\.rows)
        #expect(rows.count == 9)
        #expect(rows.first { $0.title == "Reports" }?.completion == "/tmp/kit-example/Reports/")
        #expect(
            try await harness.asyncSections(for: "/tmp/kit-example/no").flatMap(\.rows).map(\.title) == ["notes.md"])
    }

    @Test func rebuildsActionsForARememberedRow() async throws {
        let row = Row(id: ItemID("file", "/tmp/kit-example/notes.md"), title: "notes.md")
        let harness = harness()
        #expect(
            harness.rootActions(for: row).map(\.id) == [
                "open", "open-with", "reveal", "copy-path", "quick-look", "share", "move-to-trash",
            ])
        try await harness.performRoot("reveal", on: row)
        #expect(harness.fakes.workspace.revealed == [URL(filePath: "/tmp/kit-example/notes.md")])
    }

    @Test func dedicatedListFiltersPreviewsAndActs() async throws {
        let harness = harness()
        try await harness.run("search", arguments: ["query": "notes"])
        #expect(harness.rows.map(\.title) == ["notes.md"])
        #expect(try await harness.loadDetail()?.body == .preview(URL(filePath: "/tmp/kit-example/notes.md")))

        let apps = try await harness.submenu("open-with")
        #expect(apps.map(\.title) == ["Editor"])
        try await harness.perform(apps[0], row: harness.selectedRow)
        #expect(harness.fakes.workspace.openedWith.map(\.bundleID) == ["com.example.editor"])

        try await harness.perform("share")
        try await harness.perform("quick-look")
        #expect(harness.shares == [[.file(URL(filePath: "/tmp/kit-example/notes.md"))]])
        #expect(harness.quickLooks == [[URL(filePath: "/tmp/kit-example/notes.md")]])

        try await harness.perform("move-to-trash")
        #expect(harness.confirmations.map(\.title) == ["Move \"notes.md\" to the Trash?"])
        #expect(harness.fakes.workspace.trashed == [URL(filePath: "/tmp/kit-example/notes.md")])
        #expect(harness.toasts.map(\.title) == ["Moved to Trash"])
    }

    @Test func customFilteringStopsWhenCancelled() async throws {
        let feature = FileSearchSketch(index: ListedFiles(paths: [root.appending(path: "notes.md")]), home: root)
        let list = FileList(feature: feature)
        let task = Task { try await list.load(ListRequest(query: "notes")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
