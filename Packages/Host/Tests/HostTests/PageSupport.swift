import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitTesting
import LauncherUI

extension PanelFixture {
    /// The context Workbench's runs get.
    var workbenchOrigin: RunOrigin {
        RunOrigin(featureID: "workbench", feature: runtime.runtime.context(for: "workbench"), launch: .root)
    }

    /// Pushes a Kit page as Workbench, as a command's `.push` outcome does.
    @discardableResult
    func open(_ page: Page) -> any PageController {
        let made = panel.makePage(page, origin: workbenchOrigin)
        panel.push(made)
        return made
    }
}

/// Opens when a test says so; loads wait on it.
@MainActor final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

/// Image rows for grids: symbols, with a glyph and a colour among them.
@MainActor final class Tiles: ListSource {
    let changes: ChangeSignal? = ChangeSignal()
    var count: Int
    var filtering: ListFiltering = .host
    var pageSize: Int?
    private(set) var requests: [ListRequest] = []
    private(set) var used: [ItemID] = []
    private(set) var pinned: [ItemID] = []

    init(count: Int) {
        self.count = count
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        requests.append(request)
        var all = (1...max(1, count)).map { index -> Row in
            let icon: Icon =
                switch index {
                case 1: .glyph("★")
                case 2: .color(.rgba(red: 1, green: 0, blue: 0, alpha: 1))
                default: .symbol("photo.\(index)")
                }
            return Row(id: ItemID("tile", String(index)), title: "Tile \(index)", icon: icon)
        }
        if count == 0 { all = [] }
        if case .custom = filtering, !request.query.isEmpty {
            all = all.filter { $0.title.localizedCaseInsensitiveContains(request.query) }
        }
        guard let pageSize else { return ListResult(sections: [ListSection("Tiles", id: "tiles", rows: all)]) }
        let start = request.page.flatMap { Int($0.value) } ?? 0
        let slice = Array(all.dropFirst(start).prefix(pageSize))
        let next = start + pageSize < all.count ? ListPageToken(String(start + pageSize)) : nil
        return ListResult(sections: [ListSection("Tiles", id: "tiles", rows: slice)], nextPage: next)
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Use", id: "use") { _ in
                self.used.append(row.id)
                return .keepOpen
            },
            Action("Pin", id: "pin", shortcut: .pin) { _ in
                self.pinned.append(row.id)
                return .keepOpen
            },
        ]
    }
}

/// A list whose loads can wait on a gate, with paging, a dropdown, a notice and details.
@MainActor final class GatedSource: ListSource {
    let changes: ChangeSignal? = ChangeSignal()
    var filtering: ListFiltering = .host
    let gate = Gate()
    var gated = false
    var titles: [String]
    var pageSize: Int?
    var notice: Notice?
    var replacementFilter: FilterDropdown?
    var failsDetail = false
    private(set) var requests: [ListRequest] = []
    private(set) var detailRequests: [ItemID] = []
    private(set) var loadsInFlight = 0

    init(titles: [String]) {
        self.titles = titles
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        requests.append(request)
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        if gated { await gate.wait() }
        var matching = titles
        if case .custom = filtering, !request.query.isEmpty {
            matching = titles.filter { $0.localizedCaseInsensitiveContains(request.query) }
        }
        if let filter = request.filter, filter != "all" {
            matching = matching.filter { $0.lowercased().hasPrefix(filter) }
        }
        let start = request.page.flatMap { Int($0.value) } ?? 0
        let slice = pageSize.map { Array(matching.dropFirst(start).prefix($0)) } ?? matching
        let next: ListPageToken? = pageSize.flatMap { size in
            start + size < matching.count ? ListPageToken(String(start + size)) : nil
        }
        let rows = slice.map { Row(id: ItemID("gated", $0), title: $0, icon: .symbol("doc")) }
        return ListResult(
            sections: [ListSection("All", id: "all", rows: rows)], nextPage: next, filter: replacementFilter,
            notice: notice)
    }

    func detail(for row: Row) async throws -> Detail? {
        detailRequests.append(row.id)
        if failsDetail { throw ActionFailure("No detail") }
        return Detail(
            .markdown("# \(row.title)"),
            metadata: [.label("Kind", value: "Text"), .separator, .tags("Tags", [Tag("a")])])
    }

    func actions(for row: Row) -> [Action] {
        [Action("Use", id: "use") { _ in .keepOpen }, Action("Inspect", id: "inspect") { _ in .keepOpen }]
    }
}

/// A detail source whose streams the test drives.
@MainActor final class Streamer: DetailSource {
    typealias Stream = AsyncThrowingStream<DetailUpdate, any Error>

    let actionsChanged: ChangeSignal? = ChangeSignal()
    var followUp: FollowUp? = FollowUp(placeholder: "Ask a follow-up")
    private(set) var continuations: [Stream.Continuation] = []
    private(set) var followUps: [String] = []
    private(set) var askedFor: [Detail] = []
    private(set) var cancelledStreams = 0

    func start() -> Stream {
        makeStream()
    }

    func followUp(_ text: String) -> Stream {
        followUps.append(text)
        return makeStream()
    }

    func actions(for detail: Detail) -> [Action] {
        askedFor.append(detail)
        return [Action("Copy Answer", id: "copy") { _ in .keepOpen }]
    }

    var current: Stream.Continuation? { continuations.last }

    private func makeStream() -> Stream {
        let (stream, continuation) = Stream.makeStream()
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancelledStreams += 1 }
        }
        continuations.append(continuation)
        return stream
    }
}

/// Records what the share menu was asked and what it shared.
@MainActor final class FakeShareSheet: ShareSheet {
    private(set) var shared: [(items: [ShareItem], option: String)] = []

    func options(for items: [ShareItem]) -> [ShareOption] {
        [ShareOption(id: "mail", title: "Mail", symbolName: "envelope"), ShareOption(id: "notes", title: "Notes")]
    }

    func share(_ items: [ShareItem], with option: ShareOption) {
        shared.append((items, option.id))
    }
}

/// Root search whose one row's subtitle changes, as a live subtitle refresh does.
@MainActor final class SubtitleRoot: RootSource {
    let changes = ChangeSignal()
    private(set) var snapshot = RootSnapshot()
    private var revision = 1
    var subtitle = "Loading"

    private var rows: [Row] {
        [
            Row(id: ItemID("demo", "first"), title: "First", subtitle: "One", icon: .symbol("1.circle")),
            Row(id: ItemID("demo", "clock"), title: "Clock", subtitle: subtitle, icon: .symbol("clock")),
        ]
    }

    func begin() -> RootSnapshot {
        revision += 1
        snapshot = RootSnapshot(
            sections: [RootSection(id: "suggested", title: "Suggested", rows: rows, kind: .suggested)],
            revision: revision)
        return snapshot
    }

    func update(query: String) -> RootSnapshot { begin() }

    func refreshSubtitle(_ text: String) {
        subtitle = text
        _ = begin()
        changes.send()
    }

    func end() {}
    func titleHighlights(for row: Row) -> [Range<Int>] { [] }
    func featureID(for row: Row) -> String? { nil }
    func row(for id: ItemID) -> Row? { rows.first { $0.id == id } }
    func didRun(_ row: Row, launch: LaunchSource) {}
    func forget(_ id: ItemID) {}
    func actions(for row: Row) -> [Action] { [Action("Open", id: "open") { _ in .keepOpen }] }
}

/// The one feature that may own `app` rows, with two sample apps.
final class SampleApps: Feature {
    static let manifest = FeatureManifest(id: "apps", name: "Apps", icon: .symbol("square.grid.2x2"))
    let catalog = SampleAppCatalog()

    init(context: FeatureContext) {}

    var catalogSources: [any CatalogSource] { [catalog] }
}

@MainActor final class SampleAppCatalog: CatalogSource {
    let namespace = ItemID.ReservedNamespace.app

    func rows() async throws -> [Row] {
        [
            Row(id: ItemID("app", "com.example.writer"), title: "Writer", icon: .app(bundleID: "com.example.writer")),
            Row(id: ItemID("app", "com.example.editor"), title: "Editor", icon: .app(bundleID: "com.example.editor")),
        ]
    }

    func actions(for row: Row) -> [Action] { [] }
}
