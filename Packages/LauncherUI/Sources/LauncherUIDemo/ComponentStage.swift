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
        State(name: "hud", caption: "HUD after closing", usesPanel: false) { stage in
            stage.hud.show(
                HUDContent("Copied to Clipboard", symbolName: "checkmark.circle.fill"), on: stage.scene.windowFrame)
        },
    ]
}

extension LauncherSurface {
    /// Lays out the query row now, so a menu anchored to a chip finds the chip in place.
    func layoutSubtreeIfNeeded() {
        rootView.layoutSubtreeIfNeeded()
    }
}
