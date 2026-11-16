import AppKit
import Kit
import KitHosting
import LauncherUI

/// A grid a command pushed: the rows of a ``ListSource`` drawn as cells by LauncherUI's
/// ``GridView``.
///
/// Loading, filtering, paging, reloads and the dropdown are the list's, through ``RowFeed``. Each
/// row's icon fills its cell: a colour as a swatch, anything else as an image from the
/// ``IconProvider`` at the cell's size. A glyph, such as an emoji, draws as an image too, because a
/// ready image costs less to draw than live text; until the provider has it, the glyph draws as
/// text. Cells are mapped once per load, so a keystroke only picks the cells that match. Arrows
/// move in two dimensions, Command-Up and Command-Down jump between sections, and Command-plus and
/// Command-minus change the column count. When the grid hides titles, the action bar names the
/// selected cell.
@MainActor public final class GridPageController: PageController {
    /// The fewest and most columns Command-minus and Command-plus allow.
    public static let columnRange = 1...12

    public let page: GridPage
    public let origin: RunOrigin
    public let contentView = PageContentView()
    public let grid = GridView()
    let emptyView = EmptyStateView()
    let banner = NoticeBanner()
    let feed: RowFeed

    /// The columns shown now: the page's, until the user changes them.
    public private(set) var columns: Int
    public var loadCount: Int { feed.loadCount }
    public var loadReasons: [LoadReason] { feed.loadReasons }
    public var notice: Notice? { feed.notice }
    /// Times the cells were mapped from rows, for tests: once per load, not per keystroke.
    public private(set) var cellBuilds = 0

    private weak var host: (any PageHost)?
    /// Mapped cells, parallel to the feed's loaded sections.
    private var cells: [[GridCell]] = []
    /// Image cells whose icon was not ready, by section and row.
    private var missingIcons: [(section: Int, row: Int, icon: Icon)] = []
    private var selected: (section: String, id: ItemID)?
    private var cellIconSize = IconSize(points: 64, scale: 2)

    public init(page: GridPage, origin: RunOrigin, preferences: HostPreferences? = nil) {
        self.page = page
        self.origin = origin
        columns = min(max(page.columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        feed = RowFeed(
            source: page.source, origin: origin, initialQuery: page.initialQuery, filter: page.filter,
            emptyState: page.emptyState, preferences: preferences, rememberKey: page.title ?? "grid")
        contentView.show(grid)
        feed.onChange = { [weak self] change in self?.feedDidChange(change) }
        feed.onLoading = { [weak self] loading in
            guard let self else { return }
            host?.page(self, isLoading: loading)
        }
        feed.onDropdownChange = { [weak self] in
            guard let self else { return }
            host?.pageFilterDidChange(self)
        }
        feed.onError = { [weak self] error in
            guard let self else { return }
            host?.pageDidFail(self, error: error)
        }
        grid.onSelect = { [weak self] _ in self?.noteSelection() }
        grid.onVisibleCellsChange = { [weak self] _ in self?.contentDidScroll() }
        grid.onActivate = { [weak self] index in
            guard let self else { return }
            grid.select(index, animated: false)
            noteSelection()
            host?.runPrimaryAction(for: self)
        }
        banner.onPress = { [weak self] in self?.runNoticeAction() }
        contentView.onThemeChange = { [weak self] theme in
            self?.banner.apply(theme)
            self?.themeDidChange()
        }
    }

    /// The page's own title, or the title of the command that pushed it.
    public var title: String? { page.title ?? origin.commandTitle }
    public var featureID: String? { origin.featureID }
    public var query: String { feed.query }
    public var searchPlaceholder: String { page.searchPlaceholder ?? HostStrings.filterPlaceholder }
    public var initialQuery: String { page.initialQuery }

    public var filter: QueryFilter? {
        guard let dropdown = feed.dropdown else { return nil }
        let options = dropdown.options.map { MenuOption(id: $0.id, title: $0.title, section: $0.section) }
        return QueryFilter(
            options: options, selectedID: feed.filterID ?? dropdown.defaultID, label: dropdown.title)
    }

    // MARK: Lifecycle

    public func pageDidAppear(in host: any PageHost) {
        self.host = host
        feed.meter = host.workMeter
        updateCellSize(host.resolvedTheme)
        banner.apply(host.resolvedTheme)
        feed.appear()
    }

    public func pageDidDisappear() {
        feed.disappear()
    }

    public func panelDidHide() {
        feed.panelDidHide()
    }

    public func panelDidShow() {
        feed.panelDidShow()
    }

    public func panelDidClose() {
        feed.panelDidClose()
    }

    public func pageWillClose() {
        feed.close()
    }

    // MARK: Input

    public func queryDidChange(_ text: String) {
        feed.setQuery(text)
    }

    public func filterDidChange(_ optionID: String) {
        feed.setFilter(optionID)
    }

    public func reload() {
        feed.reload()
    }

    public func moveSelection(_ move: SelectionMove) -> Bool {
        guard grid.content.cellCount > 0 else { return false }
        switch move {
        case .up: grid.moveSelection(.up, animated: true)
        case .down: grid.moveSelection(.down, animated: true)
        case .previousSection: grid.moveSelectionToSection(forward: false, animated: true)
        case .nextSection: grid.moveSelectionToSection(forward: true, animated: true)
        }
        didMoveSelection()
        return true
    }

    public func handle(_ command: QueryCommand) -> Bool {
        switch command {
        case .moveLeft, .moveRight:
            guard grid.content.cellCount > 0 else { return false }
            host?.probe.begin(.selection)
            grid.moveSelection(command == .moveLeft ? .left : .right, animated: true)
            didMoveSelection()
            host?.probe.markApplied()
            return true
        case .chord(let chord)
        where (chord.modifiers == .command || chord.modifiers == [.command, .shift])
            && ["=", "+", "-"].contains(chord.key):
            setColumns(columns + (chord.key == "-" ? 1 : -1))
            return true
        default:
            return false
        }
    }

    /// Shows `count` columns, within ``columnRange``. Command-plus shows fewer, larger cells.
    public func setColumns(_ count: Int) {
        let clamped = min(max(count, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        guard clamped != columns else { return }
        columns = clamped
        if let theme = host?.resolvedTheme { updateCellSize(theme) }
        buildCells()
        render(keepSelection: true)
    }

    public func contentDidScroll() {
        let count = grid.content.cellCount
        guard count > 0, feed.canLoadNextPage, let last = grid.cellRect(count - 1) else { return }
        if last.minY < grid.bounds.height + last.height * 2 { feed.loadNextPage() }
    }

    public var target: ActionTarget? {
        if let index = grid.selectedIndex { return target(at: index) }
        guard let emptyState = feed.emptyState, !emptyState.actions.isEmpty, feed.hasLoaded,
            let runtime = host?.runtime
        else { return nil }
        let entries = runtime.visible(emptyState.actions).map {
            ActionEntry($0, featureID: origin.featureID, context: origin.feature)
        }
        var target = ActionTarget(
            row: nil, entries: entries, featureID: origin.featureID, context: origin.feature, launch: .page,
            query: feed.query)
        target.panelExtras = noticeEntries(runtime)
        return target
    }

    public func target(at index: Int) -> ActionTarget? {
        guard let row = row(at: index), let runtime = host?.runtime else { return nil }
        let entries = runtime.visible(page.source.actions(for: row)).map {
            ActionEntry($0, featureID: origin.featureID, context: origin.feature)
        }
        var target = ActionTarget(
            row: row, entries: entries, featureID: origin.featureID, context: origin.feature, launch: .page,
            query: feed.query)
        target.panelExtras = noticeEntries(runtime)
        return target
    }

    /// The notice's button as an action panel entry, so the keyboard reaches it too.
    private func noticeEntries(_ runtime: FeatureRuntime) -> [ActionEntry] {
        guard let action = feed.notice?.action, !runtime.visible([action]).isEmpty else { return [] }
        return [ActionEntry(action, featureID: origin.featureID, context: origin.feature)]
    }

    public func iconsDidChange() {
        guard !missingIcons.isEmpty, let mapper = host?.rowMapper else { return }
        var still: [(section: Int, row: Int, icon: Icon)] = []
        // A glyph drawn as text until now changes the kind of its cell, which the grid draws only
        // from new content.
        var redraw = false
        for missing in missingIcons {
            guard cells.indices.contains(missing.section), cells[missing.section].indices.contains(missing.row) else {
                continue
            }
            guard let image = mapper.icons.image(for: missing.icon, size: cellIconSize, isDark: mapper.isDark) else {
                still.append(missing)
                continue
            }
            if case .image = cells[missing.section][missing.row].content {
                grid.setImage(image, forCell: cells[missing.section][missing.row].id)
            } else {
                redraw = true
            }
            cells[missing.section][missing.row].content = .image(image)
        }
        missingIcons = still
        if redraw { render(keepSelection: true) }
    }

    public func appearanceDidChange() {
        buildCells()
        render(keepSelection: true)
    }

    /// The selected row, if any.
    public var selectedRow: Row? { grid.selectedIndex.flatMap(row(at:)) }

    /// The selected cell's title while the grid hides titles, so the action bar says what Return
    /// acts on.
    public var selectionTitle: String? {
        guard !page.showsTitles else { return nil }
        return selectedRow?.title
    }

    /// True while the page loads, or its source says it is busy with work of its own, through
    /// Kit's `BusySource`.
    public var isBusy: Bool { feed.isLoading || feed.sourceIsBusy }

    // MARK: Cells

    private func themeDidChange() {
        guard let theme = host?.resolvedTheme else { return }
        let old = cellIconSize
        updateCellSize(theme)
        if old != cellIconSize, feed.hasLoaded {
            buildCells()
            render(keepSelection: true)
        }
    }

    private func updateCellSize(_ theme: ResolvedTheme) {
        let metrics = theme.theme.grid
        let width = theme.theme.panel.width - metrics.horizontalInset * 2 - metrics.spacing * Double(columns - 1)
        let tile = max(16, width / Double(columns) - metrics.imagePadding * 2)
        cellIconSize = IconSize(points: tile.rounded(), scale: Double(contentView.window?.backingScaleFactor ?? 2))
    }

    /// Maps every loaded row to a cell, once per load.
    private func buildCells() {
        guard let mapper = host?.rowMapper else { return }
        cellBuilds += 1
        missingIcons.removeAll(keepingCapacity: true)
        cells = feed.loadedSections.enumerated().map { sectionIndex, section in
            section.rows.enumerated().map { rowIndex, row in
                var content: GridCellContent
                switch row.icon {
                case .glyph(let glyph):
                    let image = mapper.icons.image(for: .glyph(glyph), size: cellIconSize, isDark: mapper.isDark)
                    if image == nil { missingIcons.append((sectionIndex, rowIndex, .glyph(glyph))) }
                    content = image.map(GridCellContent.image) ?? .glyph(glyph)
                case .color(let color): content = .color(RowMapper.themeColor(color))
                case .none: content = .image(nil)
                case .some(let icon):
                    let image = mapper.icons.image(for: icon, size: cellIconSize, isDark: mapper.isDark)
                    if image == nil { missingIcons.append((sectionIndex, rowIndex, icon)) }
                    content = .image(image)
                }
                return GridCell(
                    id: row.id.engineKey, content: content, title: row.title, subtitle: row.subtitle ?? "",
                    accessibilityLabel: row.title)
            }
        }
    }

    // MARK: Drawing

    private func feedDidChange(_ change: RowFeed.Change) {
        if change != .filtered { buildCells() }
        render(keepSelection: true)
    }

    private func render(keepSelection: Bool) {
        guard let host else { return }
        let meter = host.workMeter
        var sections: [GridSection] = []
        sections.reserveCapacity(feed.shown.count)
        var count = 0
        let highlights = page.showsTitles && !feed.query.isEmpty
        for shown in feed.shown where cells.indices.contains(shown.section) {
            let sectionCells = cells[shown.section]
            var picked: [GridCell] = []
            picked.reserveCapacity(shown.rows.count)
            for (position, rowIndex) in shown.rows.enumerated() where sectionCells.indices.contains(rowIndex) {
                var cell = sectionCells[rowIndex]
                if highlights, shown.highlights.indices.contains(position) {
                    cell.titleHighlights = RowMapper.ranges(shown.highlights[position])
                }
                picked.append(cell)
            }
            count += picked.count
            let section = feed.loadedSections[shown.section]
            sections.append(
                GridSection(title: section.title, cells: picked, count: section.showsCount ? picked.count : nil))
        }
        let content = GridContent(
            sections: sections, columns: .fixed(columns), aspectRatio: page.aspectRatio,
            showsTitles: page.showsTitles, emphasizesMatches: highlights)
        let grid = grid
        meter.measure { grid.apply(content) }
        meter.measure {
            if count == 0 && feed.hasLoaded {
                let empty = feed.emptyState ?? EmptyState(title: HostStrings.noResults)
                emptyView.apply(
                    EmptyStateContent(
                        symbolName: RowMapper.symbolName(empty.icon) ?? "square.grid.2x2", title: empty.title,
                        hint: empty.message))
                contentView.show(emptyView)
            } else {
                contentView.show(grid)
            }
            renderBanner(host.resolvedTheme)
        }
        var index = 0
        if keepSelection, let selected, let found = flatIndex(of: selected) { index = found }
        meter.measure { grid.select(count > 0 ? index : nil, animated: false) }
        noteSelection()
    }

    private func renderBanner(_ theme: ResolvedTheme) {
        guard let notice = feed.notice else {
            contentView.setBanner(nil, height: 0)
            return
        }
        banner.apply(
            NoticeContent(
                icon: .symbol(RowMapper.symbolName(notice.icon) ?? "info.circle"), title: notice.title,
                message: notice.message, buttonTitle: notice.action?.title))
        contentView.setBanner(banner, height: NoticeBanner.preferredHeight(for: theme))
    }

    private func runNoticeAction() {
        guard let action = feed.notice?.action, let runtime = host?.runtime else { return }
        runtime.pipeline.perform(
            action, featureID: origin.featureID, context: origin.feature, query: feed.query, launch: .page,
            row: selectedRow)
    }

    private func didMoveSelection() {
        noteSelection()
        if let index = grid.selectedIndex, index >= grid.content.cellCount - columns * 2 { feed.loadNextPage() }
    }

    private func noteSelection() {
        if let index = grid.selectedIndex, let (section, row) = position(of: index) {
            selected = (feed.loadedSections[section].id, feed.loadedSections[section].rows[row].id)
        } else {
            selected = nil
        }
        host?.pageSelectionDidChange(self)
    }

    // MARK: Positions

    private func row(at index: Int) -> Row? {
        position(of: index).flatMap { feed.row(section: $0.0, row: $0.1) }
    }

    private func position(of index: Int) -> (Int, Int)? {
        guard index >= 0 else { return nil }
        var remaining = index
        for shown in feed.shown {
            if remaining < shown.rows.count { return (shown.section, shown.rows[remaining]) }
            remaining -= shown.rows.count
        }
        return nil
    }

    private func flatIndex(of key: (section: String, id: ItemID)) -> Int? {
        var offset = 0
        var fallback: Int?
        for shown in feed.shown {
            let section = feed.loadedSections[shown.section]
            if let position = shown.rows.firstIndex(where: { section.rows[$0].id == key.id }) {
                if section.id == key.section { return offset + position }
                fallback = fallback ?? offset + position
            }
            offset += shown.rows.count
        }
        return fallback
    }
}
