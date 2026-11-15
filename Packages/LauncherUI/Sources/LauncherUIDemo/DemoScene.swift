import AppKit
import LauncherUI
import LauncherUITesting

/// A launcher wired to the synthetic catalog, standing in for the real host: it filters on every
/// keystroke, fills the ghost completion and the action bar, and moves the selection.
///
/// The panel sits in the bottom-left corner of the main screen, away from where people look,
/// and never follows the pointer.
final class DemoScene: QueryFieldDelegate {
    let surface: LauncherSurface
    let summoner: Summoner
    let list = ResultListView()
    let catalog = SyntheticCatalog()
    var rowStyle: RowStyle = .oneLine
    /// Pad results to this many rows with unmatched items, as a large catalog would fill them,
    /// so the glass height stays the same while typing. Zero shows only the matches.
    var minimumRows = 0

    init(theme: Theme = .standard, strategy: SummonStrategy = .layerOpacity) {
        surface = LauncherSurface(theme: theme)
        summoner = Summoner(surface: surface, strategy: strategy)
        summoner.followsPointerScreen = false
        surface.setContent(list, animated: false)
        surface.queryField.delegate = self
        surface.queryField.placeholder = "Search apps and commands"
        list.onActivate = { _ in }
        placeInCorner()
        showRoot()
    }

    /// The window's frame on screen, which is also the capture rectangle.
    var windowFrame: CGRect { surface.panel.frame }

    func placeInCorner() {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        surface.place(windowOrigin: CGPoint(x: visible.minX + 16, y: visible.minY + 16))
    }

    /// The empty-query root: Suggested, then Favorites.
    func showRoot() {
        surface.queryField.text = ""
        surface.queryField.ghostText = ""
        apply(catalog.rootContent(), viewTitle: "Search")
    }

    /// Every kind of text at once, for contrast sweeps: a header, matched and dimmed titles,
    /// subtitles, accessories, tags and keycaps.
    func showLegibilityContent() {
        surface.queryField.text = "co"
        var content = catalog.content(for: "co", limit: 9)
        content.sections[0].title = "Results"
        surface.queryField.ghostText = ""
        apply(content, viewTitle: "Search")
    }

    /// The results for `query`, as if typed.
    func show(query: String) {
        surface.queryField.text = query
        update(for: query)
    }

    private func update(for query: String) {
        guard !query.isEmpty else {
            showRoot()
            return
        }
        var content = catalog.content(for: query, rowStyle: rowStyle)
        if content.rowCount < minimumRows, var rows = content.sections.first?.rows {
            let shown = Set(rows.map(\.id))
            let filler = catalog.rotatingContent(step: 0, count: catalog.items.count).sections[0].rows
                .filter { !shown.contains($0.id) }.map { row -> ListRow in
                    var row = row
                    row.titleHighlights = []
                    return row
                }
            rows += filler.prefix(minimumRows - rows.count)
            content.sections[0].rows = rows
        }
        let top = content.sections.first?.rows.first
        var ghost = ""
        if let title = top?.title, title.lowercased().hasPrefix(query.lowercased()), title.count > query.count {
            ghost = String(title.dropFirst(query.count))
        }
        surface.queryField.ghostText = ghost
        apply(content, viewTitle: "Search")
    }

    private func apply(_ content: ListContent, viewTitle: String) {
        list.apply(content)
        list.select(content.rowCount > 0 ? 0 : nil, animated: false)
        updateActionBar()
    }

    private func updateActionBar() {
        let selected = list.selectedRow.flatMap { list.row(at: $0) }
        let primary = selected.map { $0.subtitle == "Application" ? "Open Application" : "Run Command" }
        surface.actionBar.apply(ActionBarContent(viewTitle: "Search", primaryTitle: primary))
    }

    // MARK: QueryFieldDelegate

    func queryField(_ field: QueryField, didChangeText text: String) {
        summoner.probe.begin(.keystroke, eventTimestamp: NSApp.currentEvent?.timestamp)
        update(for: text)
        summoner.probe.markApplied()
    }

    func queryField(_ field: QueryField, perform command: QueryCommand) -> Bool {
        switch command {
        case .moveDown, .moveUp:
            summoner.probe.begin(.selection, eventTimestamp: NSApp.currentEvent?.timestamp)
            list.moveSelection(by: command == .moveDown ? 1 : -1, animated: true)
            updateActionBar()
            summoner.probe.markApplied()
            return true
        case .moveToNextSection, .moveToPreviousSection:
            list.moveSelectionToSection(forward: command == .moveToNextSection)
            updateActionBar()
            return true
        case .complete:
            guard !field.ghostText.isEmpty else { return false }
            field.text += field.ghostText
            update(for: field.text)
            return true
        default:
            return false
        }
    }
}
