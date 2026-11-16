import AppKit
import LauncherUI
import LauncherUITesting

/// The part 2 components on the demo scene's panel, one state at a time: grids, the detail pane,
/// the cards, a form, the query row's chips and menu, the empty state with the loading bar, and
/// the HUD. Each state starts from the root list, so states never leak into each other.
final class ComponentStage {
    /// One state to capture.
    struct State {
        let name: String
        let caption: String
        /// Whether the capture needs the panel. The HUD is its own window.
        var usesPanel = true
        let setUp: @MainActor (ComponentStage) -> Void
    }

    let scene: DemoScene
    let grid = GridView()
    let split = ListDetailView()
    let detailPage = DetailPane()
    let form = FormView()
    let empty = EmptyStateView()
    let notice = NoticeStageView()
    let hud = HUDWindow()
    private(set) var actionCard: ActionCardView?

    init(scene: DemoScene) {
        self.scene = scene
        hud.prewarm()
    }

    var surface: LauncherSurface { scene.surface }

    /// Back to the root list with a plain query row and nothing over it.
    func reset() {
        surface.dismissOverlay()
        surface.isLoading = false
        surface.queryField.arguments = []
        surface.queryField.filter = nil
        surface.queryField.leading = .root
        surface.queryField.placeholder = "Search apps and commands"
        surface.setContent(scene.list, animated: false)
        surface.queryField.installEditor()
        scene.showRoot()
        surface.actionBar.show(nil)
    }

    static let states: [State] = [
        State(name: "grid-glyph", caption: "glyph grid, 8 columns") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Search Emoji")
            stage.surface.queryField.placeholder = "Search emoji"
            stage.surface.setContent(stage.grid, animated: false)
            stage.grid.apply(SyntheticComponents.glyphGrid())
            stage.grid.select(10, animated: false)
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Search Emoji", primaryTitle: "Paste Emoji"))
        },
        State(name: "grid-image", caption: "image grid, 5 columns") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Screenshots")
            stage.surface.queryField.text = "a"
            stage.surface.setContent(stage.grid, animated: false)
            var content = SyntheticComponents.imageGrid()
            content.emphasizesMatches = true
            content.sections[0].cells = SyntheticComponents.filter(content.sections[0].cells, by: "a")
            stage.grid.apply(content)
            stage.grid.select(1, animated: false)
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Screenshots", primaryTitle: "Open"))
        },
        State(name: "detail-markdown", caption: "list and Markdown detail") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Clipboard History")
            stage.surface.queryField.filter = QueryFilter(
                options: SyntheticComponents.filterOptions, selectedID: "all", label: "Type")
            stage.surface.setContent(stage.split, animated: false)
            stage.split.list.apply(SyntheticComponents.historyRows())
            stage.split.list.select(0, animated: false)
            stage.split.detail.apply(
                DetailContent(body: .markdown(SyntheticComponents.markdown), metadata: SyntheticComponents.metadata))
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Clipboard History", primaryTitle: "Paste"))
        },
        State(name: "detail-image", caption: "list and image detail") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Clipboard History")
            stage.surface.setContent(stage.split, animated: false)
            stage.split.list.apply(SyntheticComponents.historyRows())
            stage.split.list.select(4, animated: false)
            stage.split.detail.apply(
                DetailContent(
                    body: .image(SyntheticComponents.picture(seed: 3, width: 640, height: 440)),
                    metadata: Array(SyntheticComponents.metadata.prefix(3))))
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Clipboard History", primaryTitle: "Paste"))
        },
        State(name: "action-card", caption: "action card") { stage in
            let card = ActionCardView(content: SyntheticComponents.actions)
            stage.actionCard = card
            stage.surface.present(card)
            card.selectItem(at: 2)
        },
        State(name: "confirm-card", caption: "confirm card, destructive") { stage in
            stage.surface.present(
                ConfirmCardView(
                    content: ConfirmContent(
                        title: "Delete 12 entries?",
                        message: "They are removed from clipboard history. This cannot be undone.",
                        confirmTitle: "Delete", isDestructive: true)))
        },
        State(name: "form", caption: "form, link field focused") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Create Quicklink")
            stage.surface.queryField.placeholder = ""
            stage.surface.setContent(stage.form, animated: false)
            stage.form.apply(SyntheticComponents.form())
            stage.form.focus("link")
            stage.surface.actionBar.apply(
                ActionBarContent(
                    viewTitle: "Create Quicklink", primaryTitle: "Save Quicklink", primaryKeys: ["⌘", "↩"]))
        },
        State(name: "arguments", caption: "argument chips and filter") { stage in
            stage.surface.queryField.text = "Search Snippets"
            stage.surface.queryField.arguments = [
                QueryArgument(placeholder: "Keyword", value: "sig"),
                QueryArgument(kind: .secure, placeholder: "Passphrase"),
                QueryArgument(
                    kind: .dropdown([MenuOption(id: "any", title: "Any Tag"), MenuOption(id: "work", title: "Work")]),
                    placeholder: "Tag", value: "work"),
            ]
            stage.surface.queryField.filter = QueryFilter(
                options: SyntheticComponents.filterOptions, selectedID: "text", label: "Type")
            stage.surface.queryField.focusArgument(1)
        },
        State(name: "filter-menu", caption: "filter dropdown open") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Clipboard History")
            stage.surface.queryField.filter = QueryFilter(
                options: SyntheticComponents.filterOptions, selectedID: "image", label: "Type")
            stage.surface.setContent(stage.split, animated: false)
            stage.split.list.apply(SyntheticComponents.historyRows())
            stage.split.list.select(4, animated: false)
            stage.split.detail.apply(
                DetailContent(body: .image(SyntheticComponents.picture(seed: 3, width: 640, height: 440))))
            stage.surface.layoutSubtreeIfNeeded()
            stage.surface.queryField.openFilterMenu()
        },
        State(name: "empty-loading", caption: "empty state, loading") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Search Files")
            stage.surface.queryField.text = "quarterly forecast"
            stage.surface.setContent(stage.empty, animated: false)
            stage.empty.apply(
                EmptyStateContent(
                    symbolName: "doc.text.magnifyingglass", title: "No Files Found",
                    hint: "Try another word, or include hidden files in Settings."))
            stage.surface.isLoading = true
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Search Files", actionsTitle: nil))
        },
        State(name: "list-sections", caption: "two-line rows under section headers") { stage in
            stage.scene.rowStyle = .twoLine
            stage.scene.show(query: "a")
            stage.scene.rowStyle = .oneLine
            var content = stage.scene.list.content
            if let rows = content.sections.first?.rows, rows.count > 4 {
                content.sections = [
                    ListSection(title: "Applications", rows: Array(rows.prefix(3))),
                    ListSection(title: "Commands", rows: Array(rows.dropFirst(3).prefix(5)), count: rows.count - 3),
                ]
            }
            stage.scene.list.apply(content)
            stage.scene.list.select(1, animated: false)
        },
        State(name: "notice", caption: "notice banner over a list") { stage in
            stage.surface.queryField.leading = QueryLeading(glyph: .back, breadcrumb: "Search Files")
            stage.surface.queryField.placeholder = "Search files"
            stage.surface.setContent(stage.notice, animated: false)
            stage.notice.banner.apply(
                NoticeContent(
                    icon: .symbol("lock"), title: "Full Disk Access is off",
                    message: "Some folders are left out.", buttonTitle: "Grant Access"))
            stage.notice.list.apply(SyntheticComponents.historyRows())
            stage.notice.list.select(0, animated: false)
            stage.surface.actionBar.apply(ActionBarContent(viewTitle: "Search Files", primaryTitle: "Open"))
        },
        State(name: "permission-card", caption: "permission card") { stage in
            stage.surface.present(
                ConfirmCardView(
                    content: ConfirmContent(
                        title: "Allow Window Layout to Use Accessibility?",
                        message: "It moves and resizes the windows you ask it to. Nothing else.",
                        confirmTitle: "Grant Access")))
        },
        State(name: "toast-ghost", caption: "ghost completion and a toast with a button") { stage in
            stage.scene.show(query: "cal")
            if stage.surface.queryField.ghostText.isEmpty { stage.surface.queryField.ghostText = "endar" }
            stage.surface.actionBar.show(
                ActionBarToast(.success, "Copied to Clipboard", buttonTitle: "Undo", buttonKeys: ["⌘", "Z"]))
        },
        State(name: "hud", caption: "HUD after closing", usesPanel: false) { stage in
            stage.hud.show(
                HUDContent("Copied to Clipboard", symbolName: "checkmark.circle.fill"), on: stage.scene.windowFrame)
        },
    ]
}

/// A list under a notice banner, as a host lays them out: the banner on top, one list row tall,
/// and the rows under it.
final class NoticeStageView: NSView, LauncherContentView {
    let banner = NoticeBanner()
    let list = ResultListView()
    private var bannerHeight: CGFloat = 0
    var contentHeightDidChange: (() -> Void)?
    var selectionLens: SelectionLens? {
        get { list.selectionLens }
        set { list.selectionLens = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(banner)
        addSubview(list)
        list.contentHeightDidChange = { [weak self] in self?.contentHeightDidChange?() }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func preferredContentHeight(limit: CGFloat) -> CGFloat {
        min(limit, list.preferredContentHeight(limit: max(0, limit - bannerHeight)) + bannerHeight)
    }

    func apply(_ theme: ResolvedTheme) {
        bannerHeight = NoticeBanner.preferredHeight(for: theme)
        banner.apply(theme)
        list.apply(theme)
        layoutChildren()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    private func layoutChildren() {
        banner.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
        list.frame = CGRect(x: 0, y: bannerHeight, width: bounds.width, height: max(0, bounds.height - bannerHeight))
    }
}

extension LauncherSurface {
    /// Lays out the query row now, so a menu anchored to a chip finds the chip in place.
    func layoutSubtreeIfNeeded() {
        rootView.layoutSubtreeIfNeeded()
    }
}
