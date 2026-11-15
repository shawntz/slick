import AppKit
import Kit
import KitHosting
import LauncherUI

/// Root search: the bottom of the navigation stack.
///
/// Each keystroke calls ``RootSource/update(query:)`` synchronously, maps the snapshot's rows and
/// applies them in one go. When Root's ``RootSource/changes`` fires, the page reads the snapshot
/// again and keeps the selection on the same row, because late sections only append. Ghost
/// completion comes from the snapshot. Root's own rows run with the launch source of their section.
@MainActor public final class RootPageController: PageController {
    public let source: any RootSource
    public let contentView = PageContentView()
    /// The list. Public for tests and captures.
    public let list = ResultListView()
    let emptyView = EmptyStateView()

    /// The snapshot drawn now.
    public private(set) var snapshot = RootSnapshot()
    /// The search text the snapshot is for.
    public private(set) var query = ""
    /// True between ``RootSource/begin()`` and ``RootSource/end()``.
    public private(set) var isInSession = false
    /// Whether ghost completion shows.
    var showsCompletion = true

    private weak var host: (any PageHost)?
    private let runtime: FeatureRuntime
    private var selected: (section: String, id: ItemID)?
    /// Rows drawn without their icon, by list row ID.
    private var missingIcons: [UInt64: Icon] = [:]
    /// Rows past the first twelve whose highlights were asked for, by flat index.
    private var highlighted: Set<Int> = []
    /// The empty-query snapshot from the last `begin()`, drawn again at dismiss.
    private var emptySnapshot: RootSnapshot?
    private var changeWatcher: Task<Void, Never>?

    public init(source: any RootSource, runtime: FeatureRuntime) {
        self.source = source
        self.runtime = runtime
        contentView.show(list)
        list.onSelect = { [weak self] _ in self?.noteSelection() }
        list.onActivate = { [weak self] index in
            guard let self else { return }
            list.select(index, animated: false)
            noteSelection()
            host?.runPrimaryAction(for: self)
        }
        list.onVisibleRowsChange = { [weak self] _ in self?.contentDidScroll() }
    }

    public var title: String? { nil }
    public var isBusy: Bool { snapshot.isLoading }
    public var searchPlaceholder: String { HostStrings.searchPlaceholder }

    // MARK: Session

    /// Starts a typing session, as at summon. Draws only when Root's prepared state differs from
    /// what is already on screen, so the common summon does no drawing.
    public func beginSession() {
        let fresh = source.begin()
        isInSession = true
        emptySnapshot = fresh
        if query.isEmpty {
            let changed =
                fresh.sections != snapshot.sections || (fresh.emptyState == nil) != (snapshot.emptyState == nil)
            snapshot = fresh
            if changed { render(keepSelection: false) }
        } else {
            snapshot = source.update(query: query)
            render(keepSelection: true)
        }
    }

    /// Ends the typing session, as when the panel closes or a page covers root search.
    public func endSession() {
        guard isInSession else { return }
        isInSession = false
        source.end()
    }

    /// Clears the query and draws the last empty state again, ready for the next summon. Runs at
    /// dismiss, off the summon path.
    public func resetForNextSummon() {
        query = ""
        if let emptySnapshot, emptySnapshot.sections != snapshot.sections || !snapshot.query.isEmpty {
            snapshot = emptySnapshot
            render(keepSelection: false)
        } else {
            moveToFirstRow()
        }
    }

    // MARK: PageController

    public func pageDidAppear(in host: any PageHost) {
        self.host = host
        watchChanges()
    }

    public func pageDidDisappear() {
        changeWatcher?.cancel()
        changeWatcher = nil
    }

    public func pageWillClose() {
        pageDidDisappear()
        endSession()
    }

    public func queryDidChange(_ text: String) {
        query = text
        let source = source
        snapshot = host?.workMeter.measure { source.update(query: text) } ?? source.update(query: text)
        render(keepSelection: false)
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
        fillHighlightsNearSelection()
        return true
    }

    /// The rows in view changed, by the wheel, the trackpad or the selection: fills highlights for
    /// the rows in view past the first twelve. The list reports the change itself.
    public func contentDidScroll() {
        guard !query.isEmpty, list.content.rowCount > 12 else { return }
        let visible = list.visibleRows.clamped(to: 12..<list.content.rowCount)
        guard let last = visible.last else { return }
        fillHighlights(visible.lowerBound...last)
    }

    public func appearanceDidChange() {
        render(keepSelection: true)
    }

    public var target: ActionTarget? {
        list.selectedRow.flatMap(target(at:))
    }

    public func target(at index: Int) -> ActionTarget? {
        guard let (sectionIndex, rowIndex) = position(of: index) else { return nil }
        let section = snapshot.sections[sectionIndex]
        return makeTarget(section.rows[rowIndex], kind: section.kind)
    }

    /// The section kind of a flat row index.
    public func sectionKind(at index: Int) -> RootSection.Kind? {
        position(of: index).map { snapshot.sections[$0.0].kind }
    }

    public func reload() {
        guard isInSession else { return }
        snapshot = source.update(query: query)
        render(keepSelection: true)
    }

    public func iconsDidChange() {
        guard !missingIcons.isEmpty, let mapper = host?.rowMapper else { return }
        for (id, icon) in missingIcons {
            guard let image = mapper.image(icon) else { continue }
            list.setIcon(image, forRow: id)
            missingIcons[id] = nil
        }
    }

    /// The rest of the top result's title after the query, or "" for none.
    public var ghostText: String {
        guard showsCompletion, !query.isEmpty else { return "" }
        return snapshot.completion?.ghostText(after: query) ?? ""
    }

    /// The selected row and its section, if any.
    public var selectedRow: (row: Row, kind: RootSection.Kind)? {
        guard let index = list.selectedRow, let (sectionIndex, rowIndex) = position(of: index) else { return nil }
        let section = snapshot.sections[sectionIndex]
        return (section.rows[rowIndex], section.kind)
    }

    // MARK: Drawing

    /// Maps the snapshot and applies it. Keeps the selection on the same row when asked and the row
    /// is still there; otherwise selects the first row.
    func render(keepSelection: Bool) {
        guard let host else { return }
        let mapper = host.rowMapper
        let meter = host.workMeter
        missingIcons.removeAll(keepingCapacity: true)
        highlighted.removeAll(keepingCapacity: true)
        var sections: [LauncherUI.ListSection] = []
        sections.reserveCapacity(snapshot.sections.count)
        var count = 0
        for section in snapshot.sections {
            var rows: [ListRow] = []
            rows.reserveCapacity(section.rows.count)
            for row in section.rows {
                let mapped = mapper.listRow(row)
                if mapped.icon == nil, let icon = row.icon { missingIcons[mapped.id] = icon }
                rows.append(mapped)
            }
            count += rows.count
            sections.append(LauncherUI.ListSection(title: section.title, rows: rows))
        }
        let content = ListContent(sections: sections, rowStyle: .oneLine, emphasizesMatches: !snapshot.query.isEmpty)
        meter.measure {
            if count == 0, let empty = snapshot.emptyState {
                emptyView.apply(
                    EmptyStateContent(
                        symbolName: RowMapper.symbolName(empty.icon) ?? "magnifyingglass", title: empty.title,
                        hint: empty.message))
                contentView.show(emptyView)
                list.apply(content)
            } else {
                list.apply(content)
                contentView.show(list)
            }
        }
        var index = 0
        if keepSelection, let selected, let found = flatIndex(of: selected) { index = found }
        meter.measure { list.select(count > 0 ? index : nil, animated: false) }
        noteSelection()
        host.page(self, isLoading: snapshot.isLoading)
    }

    private func moveToFirstRow() {
        list.select(list.content.rowCount > 0 ? 0 : nil, animated: false)
        noteSelection()
    }

    private func noteSelection() {
        if let index = list.selectedRow, let (sectionIndex, rowIndex) = position(of: index) {
            let section = snapshot.sections[sectionIndex]
            selected = (section.id, section.rows[rowIndex].id)
        } else {
            selected = nil
        }
        host?.pageSelectionDidChange(self)
    }

    /// Root fills highlights for the first twelve rows. Rows past them get theirs as the selection
    /// brings them into view.
    private func fillHighlightsNearSelection() {
        guard !query.isEmpty, let selectedIndex = list.selectedRow, selectedIndex >= 12 else { return }
        let visible = host?.resolvedTheme.theme.list.maxVisibleRows ?? 9
        let first = max(12, selectedIndex - visible)
        let last = min(selectedIndex + 1, list.content.rowCount - 1)
        guard first <= last else { return }
        fillHighlights(first...last)
    }

    /// Asks Root for the highlights of rows past the first twelve that have none yet.
    private func fillHighlights(_ range: ClosedRange<Int>) {
        let first = range.lowerBound
        let last = range.upperBound
        var content = list.content
        var changed = false
        var flat = 0
        for sectionIndex in content.sections.indices {
            for rowIndex in content.sections[sectionIndex].rows.indices {
                defer { flat += 1 }
                guard flat >= first, flat <= last, !highlighted.contains(flat) else {
                    continue
                }
                highlighted.insert(flat)
                let row = snapshot.sections[sectionIndex].rows[rowIndex]
                guard row.titleHighlights.isEmpty else { continue }
                let ranges = RowMapper.ranges(source.titleHighlights(for: row))
                guard !ranges.isEmpty else { continue }
                content.sections[sectionIndex].rows[rowIndex].titleHighlights = ranges
                changed = true
            }
        }
        if changed { list.apply(content) }
    }

    private func watchChanges() {
        changeWatcher?.cancel()
        let stream = source.changes.stream()
        changeWatcher = Task { [weak self] in
            for await _ in stream {
                self?.sourceDidChange()
            }
        }
    }

    private func sourceDidChange() {
        guard isInSession else { return }
        let fresh = source.snapshot
        guard fresh.revision != snapshot.revision else { return }
        host?.probe.begin(.selection)
        snapshot = fresh
        render(keepSelection: true)
        host?.probe.markApplied()
    }

    // MARK: Positions and targets

    private func position(of index: Int) -> (Int, Int)? {
        guard index >= 0 else { return nil }
        var remaining = index
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            if remaining < section.rows.count { return (sectionIndex, remaining) }
            remaining -= section.rows.count
        }
        return nil
    }

    private func flatIndex(of key: (section: String, id: ItemID)) -> Int? {
        var offset = 0
        var fallback: Int?
        for section in snapshot.sections {
            if let row = section.rows.firstIndex(where: { $0.id == key.id }) {
                if section.id == key.section { return offset + row }
                fallback = fallback ?? offset + row
            }
            offset += section.rows.count
        }
        return fallback
    }

    /// The target for a root row: Run and the command's row actions for a command, Root's actions
    /// for anything else. Actions whose command is unavailable are hidden.
    func makeTarget(_ row: Row, kind: RootSection.Kind) -> ActionTarget {
        let launch = kind.launchSource
        if row.id.namespace == ItemID.ReservedNamespace.command, let command = runtime.command(row.id) {
            let context = runtime.context(for: command.featureID)
            var entries = [ActionEntry(title: HostStrings.runCommand, icon: nil, kind: .command(command))]
            if let rowActions = command.command.rowActions {
                entries += runtime.visible(rowActions()).map {
                    ActionEntry($0, featureID: command.featureID, context: context)
                }
            }
            var target = ActionTarget(
                row: row, entries: entries, featureID: command.featureID, context: context, launch: launch,
                query: query, isRoot: true)
            target.universalInsertIndex = 1
            return target
        }
        let source = source
        let featureID = source.featureID(for: row) ?? HostSettings.namespace
        let context = runtime.context(for: featureID)
        let actions = host?.workMeter.measure { source.actions(for: row) } ?? source.actions(for: row)
        let entries = runtime.visible(actions).map {
            ActionEntry($0, featureID: featureID, context: context)
        }
        return ActionTarget(
            row: row, entries: entries, featureID: featureID, context: context, launch: launch, query: query,
            isRoot: true)
    }
}
