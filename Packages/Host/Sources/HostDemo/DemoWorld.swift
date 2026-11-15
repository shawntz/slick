import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import LauncherUITesting

/// Icons drawn from SF Symbols as coloured tiles, one hue per symbol, cached by symbol and size.
@MainActor final class DemoIconProvider: IconProvider {
    let changes = ChangeSignal()
    private var cache: [String: CGImage] = [:]

    func image(for icon: Icon, size: IconSize, isDark: Bool) -> CGImage? {
        let name: String
        switch icon {
        case .symbol(let symbol, _): name = symbol
        case .app(let bundleID): name = Self.symbol(forApp: bundleID)
        case .fileType: name = "doc.text"
        case .adaptive(let light, let dark): return image(for: isDark ? dark : light, size: size, isDark: isDark)
        default: name = "questionmark"
        }
        if let cached = cache[name] { return cached }
        let hue = Double(FNV1a.hash64(name) % 360) / 360
        let image = SyntheticCatalog.icon(symbol: name, hue: hue, muted: false)
        cache[name] = image
        return image
    }

    func prepare(_ icons: [Icon], size: IconSize) {}

    private static func symbol(forApp bundleID: String) -> String {
        let symbols = ["map", "envelope", "terminal", "note.text", "calendar", "music.note", "camera", "globe"]
        return symbols[Int(FNV1a.hash64(bundleID) % UInt64(symbols.count))]
    }
}

/// HUDs dropped: the demo never shows a window outside its corner.
@MainActor final class SilentHUD: HUDDisplay {
    func show(_ hud: HUD) {}
    func prewarm() {}
    func apply(_ theme: Theme) {}
}

/// An invented feature: a clipboard-like history list, a copy command that reports with a toast,
/// a command that asks before it clears, and universal actions for text.
final class DemoFeature: Feature {
    static let manifest = FeatureManifest(id: "demo", name: "Demo", icon: .symbol("sparkles"))
    let history: DemoHistory
    let photos = DemoPhotos()
    let notes = DemoNotes()
    let files = DemoFiles()

    init(context: FeatureContext) {
        history = DemoHistory(clock: context.clock)
    }

    var commands: [Command] {
        [
            Command(id: "history", title: "Clipboard History", subtitle: "Demo", icon: .symbol("doc.on.clipboard")) {
                _ in
                .push(.list(ListPage(self.history, title: "Clipboard History", searchPlaceholder: "Search history")))
            },
            Command(id: "copy", title: "Copy Sample Text", subtitle: "Demo", icon: .symbol("doc.on.doc")) { context in
                context.showToast(.success("Copied to Clipboard"))
                return .keepOpen
            },
            Command(id: "photos", title: "Photo Library", subtitle: "Demo", icon: .symbol("photo.on.rectangle")) { _ in
                .push(.grid(GridPage(self.photos, title: "Photo Library", columns: 6, showsTitles: true)))
            },
            Command(id: "notes", title: "Search Notes", subtitle: "Demo", icon: .symbol("note.text")) { _ in
                .push(.list(ListPage(self.notes, title: "Notes", showsDetail: true)))
            },
            Command(id: "ask", title: "Ask About Glass", subtitle: "Demo", icon: .symbol("sparkles")) { _ in
                .push(.detail(DetailPage(title: "Answer", source: DemoAnswer())))
            },
            Command(id: "new-link", title: "Create Quicklink", subtitle: "Demo", icon: .symbol("link.badge.plus")) {
                _ in .push(.form(DemoForms.quicklink))
            },
            Command(id: "files", title: "Search Files", subtitle: "Demo", icon: .symbol("doc.text.magnifyingglass")) {
                _ in
                .push(.list(ListPage(self.files, title: "Files", filter: DemoFiles.kinds)))
            },
            Command(
                id: "clear", title: "Clear History", subtitle: "Demo", icon: .symbol("trash"),
                confirmation: Confirmation(
                    "Clear the whole history?", message: "Every entry is deleted. This cannot be undone.",
                    confirmTitle: "Clear History", isDestructive: true)
            ) { _ in .close(hud: "History Cleared") },
        ]
    }

    var universalActions: [UniversalActionProvider] {
        [
            .text { _ in
                [
                    Action("Search the Web", id: "web", icon: .symbol("globe")) { _ in .close() },
                    Action("Translate", id: "translate", icon: .symbol("character.bubble")) { _ in .close() },
                ]
            }
        ]
    }
}

/// The history list: two days of invented entries.
@MainActor final class DemoHistory: ListSource {
    private let clock: any ClockService

    init(clock: any ClockService) {
        self.clock = clock
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let now = clock.now
        func row(_ index: Int, _ text: String, minutes: Double, kind: String) -> Row {
            Row(
                id: ItemID("demo", String(index)), title: text,
                icon: .symbol(kind == "Link" ? "link" : "text.alignleft"),
                accessories: [
                    .tag(kind, color: kind == "Link" ? .blue : .gray), .date(now.addingTimeInterval(-minutes * 60)),
                ])
        }
        return ListResult(sections: [
            ListSection(
                "Today", showsCount: true,
                rows: [
                    row(1, "Meeting notes for the design review", minutes: 4, kind: "Text"),
                    row(2, "https://example.com/handbook/onboarding", minutes: 25, kind: "Link"),
                    row(3, "let threshold = 0.25", minutes: 52, kind: "Text"),
                    row(4, "Quarterly planning outline", minutes: 130, kind: "Text"),
                ]),
            ListSection(
                "Yesterday", showsCount: true,
                rows: [
                    row(5, "https://example.org/docs/getting-started", minutes: 1500, kind: "Link"),
                    row(6, "Remember to water the plants", minutes: 1620, kind: "Text"),
                    row(7, "Invoice 0042 sent", minutes: 1800, kind: "Text"),
                ]),
        ])
    }

    func actions(for row: Row) -> [Action] {
        [
            Action("Paste", id: "paste", icon: .symbol("doc.on.clipboard")) { _ in .close() },
            Action("Copy", id: "copy", icon: .symbol("doc.on.doc")) { _ in .keepOpen },
            Action("Delete", id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive) { _ in
                .keepOpen
            },
        ]
    }
}

/// Root search rows: invented apps, the demo's commands and a file.
enum DemoRows {
    static func all() -> [Row] {
        func app(_ name: String, _ key: String) -> Row {
            Row(
                id: ItemID("app", "com.example." + key), title: name, subtitle: "Application", icon: .app(bundleID: key)
            )
        }
        func command(_ id: String, _ title: String, _ symbol: String) -> Row {
            Row(id: .command(feature: "demo", command: id), title: title, subtitle: "Demo", icon: .symbol(symbol))
        }
        return [
            app("Atlas Maps", "atlas"), command("history", "Clipboard History", "doc.on.clipboard"),
            app("Brightline Mail", "brightline"), command("copy", "Copy Sample Text", "doc.on.doc"),
            app("Cinder Terminal", "cinder"), app("Drift Notes", "drift"), app("Ember Calendar", "ember"),
            command("clear", "Clear History", "trash"),
            command("photos", "Photo Library", "photo.on.rectangle"), command("notes", "Search Notes", "note.text"),
            command("ask", "Ask About Glass", "sparkles"), command("new-link", "Create Quicklink", "link.badge.plus"),
            command("files", "Search Files", "doc.text.magnifyingglass"),
            Row(
                id: ItemID("file", "/tmp/example/notes.md"), title: "Project Notes", subtitle: "~/example",
                icon: .fileType("md"), accessories: [.tag("Markdown", color: .purple)],
                represents: .text("Project Notes")),
            app("Fable Music", "fable"), app("Glint Camera", "glint"), app("Harbor Browser", "harbor"),
        ]
    }

    static func actions(for row: Row) -> [Action] {
        [
            Action("Open", id: "open", icon: .symbol("arrow.up.forward.app")) { _ in .close() },
            Action("Show in Finder", id: "reveal", icon: .symbol("folder"), shortcut: .reveal) { _ in .keepOpen },
            Action("Copy Path", id: "copy-path", icon: .symbol("doc.on.doc"), shortcut: .copyPath) { _ in .keepOpen },
            Action("Quick Look", id: "quick-look", icon: .symbol("eye"), shortcut: .quickLook) { _ in .keepOpen },
            Action("Move to Trash", id: "trash", icon: .symbol("trash"), style: .destructive) { _ in .keepOpen },
        ]
    }
}

/// The panel over a runtime with the demo feature and fake root search, in the bottom-left corner
/// of the main screen, never following the pointer.
@MainActor final class DemoWorld {
    let fakes = FakeServices()
    let runtime: FeatureRuntime
    let root: any RootSource
    let panel: PanelController

    /// - Parameter root: Root search; nil uses fake root search over ``DemoRows``.
    init(root: (any RootSource)? = nil) async {
        fakes.settings.set(.int(0), for: HostSettings.namespace + ".resetToRootAfter")
        runtime = FeatureRuntime(
            services: fakes.services, environment: .bench,
            dataDirectory: fakes.storage.root.appending(path: "host", directoryHint: .isDirectory))
        await runtime.start([FeatureRegistration(DemoFeature.self)])
        let source: any RootSource
        if let root {
            source = root
        } else {
            let fake = FakeRootSource(rows: DemoRows.all())
            fake.rowActions = { DemoRows.actions(for: $0) }
            source = fake
        }
        self.root = source
        panel = PanelController(runtime: runtime, rootSource: source, icons: DemoIconProvider(), hud: SilentHUD())
        panel.summoner.followsPointerScreen = false
        panel.summoner.takesKeyStatus = false
        let visible = NSScreen.main?.visibleFrame ?? .zero
        panel.surface.place(windowOrigin: CGPoint(x: visible.minX + 16, y: visible.minY + 16))
        panel.prewarm()
    }

    var windowFrame: CGRect { panel.surface.panel.frame }

    func type(_ text: String) {
        let field = panel.surface.queryField
        field.text = text
        panel.queryField(field, didChangeText: text)
    }
}

func pause(ms: Double) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}
