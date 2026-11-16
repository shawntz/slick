import AppKit
import Kit
import LauncherUI

/// A list a command pushed.
///
/// Loading and filtering live in ``RowFeed``, which grids share. The page draws the feed's rows,
/// keys the selection by section and row ID, draws ``ListResult/notice`` as a banner, loads the
/// next page when the selection or the scroll position nears the end, and, when
/// ``ListPage/showsDetail`` is set, fills a detail pane beside the rows about 50 ms after the
/// selection settles, cancelling the load when the selection moves on.
@MainActor public final class ListPageController: PageController {
    /// How long the selection must rest before the detail pane loads.
    public static let detailDelay: Duration = .milliseconds(50)

    public let page: ListPage
    /// The feature that pushed the page and how.
    public let origin: RunOrigin
    public let contentView = PageContentView()
    /// The rows: alone, or the left side of ``split`` when the page shows details.
    public let list: ResultListView
    /// The list and the detail pane, when ``ListPage/showsDetail`` is set.
    public let split: ListDetailView?
    let emptyView = EmptyStateView()
    let banner = NoticeBanner()
    let feed: RowFeed

    /// The selected dropdown option.
    public var filterID: String? { feed.filterID }
    /// The dropdown shown now: the page's, or the last one a load returned.
    public var dropdown: FilterDropdown? { feed.dropdown }
    /// The sections as the source returned them.
    public var loadedSections: [Kit.ListSection] { feed.loadedSections }
    /// The sections shown.
    public var sections: [Kit.ListSection] { feed.sections }
    public var emptyState: EmptyState? { feed.emptyState }
    /// The banner from the last load, drawn above the rows.
    public var notice: Notice? { feed.notice }
    /// Loads that finished, for tests.
    public var loadCount: Int { feed.loadCount }
    /// The reason of every load started, for tests.
    public var loadReasons: [LoadReason] { feed.loadReasons }
    /// Details the pane loaded, for tests.
    public private(set) var detailLoads = 0
    /// The row selected when the rows show and the user has selected nothing that still shows,
    /// such as Cancel on the page that asks before a link runs a command. Nil, or a row that does
    /// not show, selects the first row.
    public var preferredSelection: ItemID?

    private weak var host: (any PageHost)?
    private var selected: (section: String, id: ItemID)?
    private var missingIcons: [UInt64: Icon] = [:]
    private var detailPresenter: DetailPresenter?
    private var detailTask: Task<Void, Never>?
    /// The row the pane shows, or is loading.
    private var detailRowID: ItemID?
    private var isLoadingDetail = false

    public init(page: ListPage, origin: RunOrigin, preferences: HostPreferences? = nil) {
        self.page = page
        self.origin = origin
        if page.showsDetail {
            let split = ListDetailView()
            self.split = split
            list = split.list
            detailPresenter = DetailPresenter(pane: split.detail)
        } else {
            split = nil
            list = ResultListView()
        }
        feed = RowFeed(
            source: page.source, origin: origin, initialQuery: page.initialQuery, filter: page.filter,
            emptyState: page.emptyState, preferences: preferences, rememberKey: page.title ?? "list")
        showRows()
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
        banner.onPress = { [weak self] in self?.runNoticeAction() }
        split?.detail.onOpenLink = { [weak self] url in self?.openLink(url) }
        contentView.onThemeChange = { [weak self] theme in self?.banner.apply(theme) }
        list.onSelect = { [weak self] _ in self?.noteSelection() }
        list.onVisibleRowsChange = { [weak self] _ in self?.contentDidScroll() }
        list.onActivate = { [weak self] index in
            guard let self else { return }
            list.select(index, animated: false)
            noteSelection()
            host?.runPrimaryAction(for: self)
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
        detailPresenter?.rowMapper = host.rowMapper
        if let theme = contentView.theme { banner.apply(theme) }
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
        detailTask?.cancel()
        detailTask = nil
        detailPresenter?.cancel()
    }

    // MARK: Input

    public func queryDidChange(_ text: String) {
        feed.setQuery(text)
    }

    public func filterDidChange(_ optionID: String) {
        feed.setFilter(optionID)
    }

    public func reload() {
        detailRowID = nil
        feed.reload()
    }

    public func moveSelection(_ move: SelectionMove) -> Bool {
        guard list.content.rowCount > 0 else { return false }
        switch move {
        case .up: list.moveSelection(by: -1)
        case .down: list.moveSelection(by: 1)
        case .previousSection: list.moveSelectionToSection(forward: false)
        case .nextSection: list.moveSelectionToSection(forward: true)
        }
        noteSelection()
        if let index = list.selectedRow, index >= list.content.rowCount - 3 { feed.loadNextPage() }
        return true
    }

    /// The rows in view changed, by the wheel, the trackpad or the selection: loads the next page
    /// when the end is near. The list reports the change itself.
    public func contentDidScroll() {
        let count = list.content.rowCount
        guard count > 0, feed.canLoadNextPage, let last = list.rowRect(count - 1) else { return }
        let rowHeight = CGFloat(host?.resolvedTheme.theme.list.rowHeight ?? 40)
        if last.minY < list.bounds.height + rowHeight * 3 { feed.loadNextPage() }
    }

    public var target: ActionTarget? {
        if let index = list.selectedRow { return target(at: index) }
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
    func noticeEntries(_ runtime: FeatureRuntime) -> [ActionEntry] {
        guard let action = feed.notice?.action, !runtime.visible([action]).isEmpty else { return [] }
        return [ActionEntry(action, featureID: origin.featureID, context: origin.feature)]
    }

    public func iconsDidChange() {
        detailPresenter?.iconsDidChange()
        guard !missingIcons.isEmpty, let mapper = host?.rowMapper else { return }
        for (id, icon) in missingIcons {
            guard let image = mapper.image(icon) else { continue }
            list.setIcon(image, forRow: id)
            missingIcons[id] = nil
        }
    }

    public func appearanceDidChange() {
        render(keepSelection: true)
    }

    /// The selected row, if any.
    public var selectedRow: Row? { list.selectedRow.flatMap(row(at:)) }

    /// What the detail pane shows now.
    public var shownDetail: Detail? { detailPresenter?.detail }

    /// True while the page loads its rows or its detail, or its source says it is busy with work of
    /// its own, through Kit's `BusySource`.
    public var isBusy: Bool { feed.isLoading || isLoadingDetail || feed.sourceIsBusy }

    // MARK: Drawing

    private func feedDidChange(_ change: RowFeed.Change) {
        if change == .loaded { detailRowID = nil }
        render(keepSelection: true)
    }

    private func showRows() {
        if let split { contentView.show(split) } else { contentView.show(list) }
    }

    private func render(keepSelection: Bool) {
        guard let host else { return }
        let mapper = host.rowMapper
        let meter = host.workMeter
        missingIcons.removeAll(keepingCapacity: true)
        var mapped: [LauncherUI.ListSection] = []
        mapped.reserveCapacity(feed.shown.count)
        var count = 0
        for shown in feed.shown {
            let section = feed.loadedSections[shown.section]
            var rows: [ListRow] = []
            rows.reserveCapacity(shown.rows.count)
            for (position, rowIndex) in shown.rows.enumerated() {
                let row = section.rows[rowIndex]
                let ranges = shown.highlights.indices.contains(position) ? shown.highlights[position] : nil
                let listRow = mapper.listRow(row, highlights: ranges)
                if listRow.icon == nil, let icon = row.icon { missingIcons[listRow.id] = icon }
                rows.append(listRow)
            }
            count += rows.count
            mapped.append(
                LauncherUI.ListSection(title: section.title, rows: rows, count: section.showsCount ? rows.count : nil))
        }
        let content = ListContent(sections: mapped, rowStyle: .oneLine, emphasizesMatches: !feed.query.isEmpty)
        let list = list
        meter.measure { list.apply(content) }
        meter.measure {
            if count == 0 && feed.hasLoaded {
                let empty = feed.emptyState ?? EmptyState(title: HostStrings.noResults)
                emptyView.apply(
                    EmptyStateContent(
                        symbolName: RowMapper.symbolName(empty.icon) ?? "tray", title: empty.title,
                        hint: empty.message))
                contentView.show(emptyView)
            } else {
                showRows()
            }
            renderBanner(host.resolvedTheme)
        }
        var index = 0
        if keepSelection, let selected, let found = flatIndex(of: selected) {
            index = found
        } else if let preferred = preferredSelection, let found = flatIndex(of: ("", preferred)) {
            index = found
        }
        meter.measure { list.select(count > 0 ? index : nil, animated: false) }
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

    private func noteSelection() {
        if let index = list.selectedRow, let (section, row) = position(of: index) {
            selected = (feed.loadedSections[section].id, feed.loadedSections[section].rows[row].id)
        } else {
            selected = nil
        }
        host?.pageSelectionDidChange(self)
        scheduleDetail()
    }

    // MARK: Detail pane

    /// A link clicked in the detail pane: a web or mail link opens at once, any other shows its
    /// target in a toast first. See ``DetailLinks``.
    private func openLink(_ url: URL) {
        guard let runtime = host?.runtime else { return }
        DetailLinks.open(url, origin: origin, pipeline: runtime.pipeline)
    }

    /// Loads the selected row's detail once the selection has rested, unless the pane already shows
    /// that row. A newer selection cancels the load.
    private func scheduleDetail() {
        guard let presenter = detailPresenter else { return }
        let row = selectedRow
        guard row?.id != detailRowID else { return }
        detailTask?.cancel()
        detailRowID = row?.id
        guard let row else {
            detailTask = nil
            isLoadingDetail = false
            presenter.show(nil)
            return
        }
        let source = page.source
        isLoadingDetail = true
        detailTask = Task { [weak self] in
            defer { if self?.detailRowID == row.id { self?.isLoadingDetail = false } }
            do {
                try await Task.sleep(for: Self.detailDelay)
                let detail = try await source.detail(for: row)
                try Task.checkCancellation()
                guard let self, detailRowID == row.id else { return }
                detailLoads += 1
                presenter.show(detail)
            } catch is CancellationError {
                return
            } catch {
                guard let self, detailRowID == row.id else { return }
                presenter.show(nil)
                host?.pageDidFail(self, error: error)
            }
        }
    }

    // MARK: Positions

    private func row(at index: Int) -> Row? {
        position(of: index).flatMap { feed.row(section: $0.0, row: $0.1) }
    }

    /// The loaded section and row behind a flat index of the shown rows.
    private func position(of index: Int) -> (Int, Int)? {
        guard index >= 0 else { return nil }
        var remaining = index
        for shown in feed.shown {
            if remaining < shown.rows.count { return (shown.section, shown.rows[remaining]) }
            remaining -= shown.rows.count
        }
        return nil
    }

    /// The flat index of a selection: in its own section when that still shows it, else the first
    /// section that does.
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
