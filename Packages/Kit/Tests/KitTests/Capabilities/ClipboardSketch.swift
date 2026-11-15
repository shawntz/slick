import Foundation
import Kit
import KitTesting
import Testing

/// Scenario 1, clipboard history: a monitor started at launch, a list with a type filter, pinned and
/// dated sections, a detail per content type, paste then copy, delete with confirmation, a setting,
/// and a permission that only the paste action needs.
final class ClipboardSketch: Feature {
    static let manifest = FeatureManifest(
        id: "clipboard", name: "Clipboard History", icon: .symbol("doc.on.clipboard"),
        permissions: [PermissionNeed(.accessibility, reason: "Paste the selected entry into the frontmost app.")],
        isEnabledByDefault: false)
    static let ignoredApps = SettingKey("ignoredApps", default: ["com.example.vault"])

    nonisolated struct Entry: Sendable {
        var id: Int
        var content: PasteboardContent
        var date: Date
        var source: String?
        var isPinned = false
    }

    let context: FeatureContext
    let changes = ChangeSignal()
    private(set) var entries: [Entry] = []
    private var monitor: Task<Void, Never>?

    init(context: FeatureContext) {
        self.context = context
    }

    func activate() async {
        let stream = context.pasteboard.entries()
        monitor = Task { [weak self] in
            for await entry in stream { self?.record(entry) }
        }
    }

    func deactivate() async {
        monitor?.cancel()
    }

    private func record(_ entry: PasteboardEntry) {
        guard let content = entry.contents.first,
            !context.settings[Self.ignoredApps].contains(entry.sourceBundleID ?? "")
        else {
            return
        }
        entries.insert(
            Entry(id: entry.changeCount, content: content, date: entry.date, source: entry.sourceBundleID), at: 0)
        changes.send()
    }

    func delete(_ id: Int) {
        entries.removeAll { $0.id == id }
        changes.send()
    }

    var commands: [Command] {
        let types = FilterDropdown(
            title: "Type",
            options: ["All", "Text", "Images", "Files", "Links"].map { FilterOption(id: $0.lowercased(), title: $0) })
        return [
            Command(id: "history", title: "Clipboard History") { _ in
                .push(.list(ListPage(ClipboardList(feature: self), filter: types, showsDetail: true)))
            }
        ]
    }

    var settingsPane: SettingsPane? {
        SettingsPane(items: [.list("Ignore copies from", key: Self.ignoredApps, itemKind: .application)])
    }
}

final class ClipboardList: ListSource {
    private unowned let feature: ClipboardSketch

    init(feature: ClipboardSketch) {
        self.feature = feature
    }

    var changes: ChangeSignal? { feature.changes }

    func load(_ request: ListRequest) async throws -> ListResult {
        let calendar = feature.context.clock.calendar
        let now = feature.context.clock.now
        let shown = feature.entries.filter { entry in
            switch (request.filter ?? "all", entry.content) {
            case ("all", _), ("text", .text), ("images", .image), ("files", .files), ("links", .url): true
            default: false
            }
        }
        return ListResult(
            sections: [
                ListSection("Pinned", rows: shown.filter(\.isPinned).map(row)),
                ListSection(
                    "Today", rows: shown.filter { !$0.isPinned && calendar.isDate($0.date, inSameDayAs: now) }.map(row)),
                ListSection(
                    "Earlier",
                    rows: shown.filter { !$0.isPinned && !calendar.isDate($0.date, inSameDayAs: now) }.map(row)),
            ].filter { !$0.rows.isEmpty })
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let entry = entry(for: row) else { return nil }
        let source = MetadataItem.label("Copied from", value: entry.source ?? "Unknown")
        switch entry.content {
        case .text(let text) where KitColor(hex: text) != nil:
            return Detail(.color(KitColor(hex: text) ?? .gray), metadata: [source])
        case .text(let text), .richText(_, let text):
            return Detail(
                .text(text, monospaced: true), metadata: [source, .label("Characters", value: "\(text.count)")])
        case .image(let data, _):
            return Detail(.image(.data(data)), metadata: [source])
        case .files(let urls):
            return Detail(urls.first.map(DetailBody.preview), metadata: [source])
        case .url(let url):
            return Detail(.link(url), metadata: [source, .link("Link", text: url.host() ?? "", url: url)])
        }
    }

    func actions(for row: Row) -> [Action] {
        guard let entry = entry(for: row) else { return [] }
        return [
            .paste(entry.content, title: "Paste to Frontmost App"),
            .copy(entry.content),
            Action(
                "Delete Entry", id: "delete", shortcut: .remove, style: .destructive,
                confirmation: Confirmation(
                    "Delete this entry?", confirmTitle: "Delete", suppressionKey: "clipboard.delete")
            ) { context in
                self.feature.delete(entry.id)
                context.reload()
                return .keepOpen
            },
        ]
    }

    private func entry(for row: Row) -> ClipboardSketch.Entry? {
        feature.entries.first { String($0.id) == row.id.key }
    }

    private func row(_ entry: ClipboardSketch.Entry) -> Row {
        Row(
            id: ItemID("clipboard", String(entry.id)), title: entry.content.plainText ?? "Image",
            accessories: [.date(entry.date)],
            quickLookURL: { if case .files(let urls) = entry.content { return urls.first } else { return nil } }())
    }
}

@Suite("Scenario: clipboard history")
struct ClipboardSketchTests {
    @Test func recordsCopiesAndOffersPasteCopyAndDelete() async throws {
        let harness = FeatureHarness(ClipboardSketch.self)
        #expect(harness.issues.isEmpty)
        await harness.activate()
        let pasteboard = harness.fakes.pasteboard
        pasteboard.simulateCopy("first note", from: "com.example.editor")
        pasteboard.simulateCopy("secret", from: "com.example.vault")
        pasteboard.simulateCopy(
            [.url(try #require(URL(string: "https://example.com/page")))], from: "com.example.browser")
        pasteboard.simulateCopy("#FF8800", from: "com.example.editor")
        while harness.feature.entries.count < 3 { await Task.yield() }

        try await harness.run("history")
        #expect(harness.sections.map(\.title) == ["Today"])
        #expect(harness.rows.map(\.title) == ["#FF8800", "https://example.com/page", "first note"])
        #expect(try await harness.loadDetail()?.body == .color(try #require(KitColor(hex: "#FF8800"))))

        try await harness.setFilter("links")
        #expect(harness.rows.count == 1)
        #expect(
            try await harness.loadDetail()?.metadata.last
                == .link("Link", text: "example.com", url: try #require(URL(string: "https://example.com/page"))))

        harness.fakes.permissions.set(.accessibility, to: .denied)
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) { try await harness.performPrimary() }
        try await harness.perform("copy")
        #expect(pasteboard.copied == [.url(try #require(URL(string: "https://example.com/page")))])

        try await harness.setFilter("all")
        try await harness.perform("delete")
        #expect(harness.confirmations.first?.suppressionKey == "clipboard.delete")
        #expect(harness.rows.count == 2)
    }
}
