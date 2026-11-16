import Foundation
import Kit

/// Loads and filters the rows of a list or grid page. Both pages use it, so a grid filters, pages,
/// reloads and swaps its dropdown exactly as a list does.
///
/// With host filtering it loads once, builds a fuzzy index off the main thread and filters on each
/// keystroke itself. With custom filtering it loads per query after the debounce, in a task it
/// cancels when the query changes. Only the newest load applies. Next pages append to the section
/// with the same ID. It loads again when the source's ``RowSource/changes`` fires, when a setting
/// in ``RowSource/reloadsOnSettings`` changes, after ``ActionContext/reload()``, and after
/// ``ListResult/refreshAfter``. Reloads that arrive while a load runs are coalesced into one more
/// load after it, so a storm of change signals costs at most two loads.
///
/// While the panel is hidden it does no work: it stops listening, holds the refresh timer and
/// defers reloads. When the panel shows again it loads once if its source changed, a reload was
/// asked for or the refresh came due while it was hidden.
@MainActor final class RowFeed {
    /// Why the shown rows changed.
    enum Change: Equatable {
        /// The query changed and the host filtered the loaded rows again.
        case filtered
        /// A load replaced the rows.
        case loaded
        /// A next page appended rows.
        case appended
    }

    let source: any ListSource
    let origin: RunOrigin

    /// The shown rows changed. The page draws them.
    var onChange: ((Change) -> Void)?
    /// A load started or ended.
    var onLoading: ((Bool) -> Void)?
    /// The dropdown or its selection changed.
    var onDropdownChange: (() -> Void)?
    /// A load failed with an error other than cancellation.
    var onError: ((any Error) -> Void)?
    /// Charged with fuzzy index searches, for budgets.
    var meter: WorkMeter?

    private(set) var query: String
    /// The selected dropdown option.
    private(set) var filterID: String?
    /// The dropdown shown now: the page's, or the last one a load returned.
    private(set) var dropdown: FilterDropdown?
    /// The sections as the source returned them, next pages included.
    private(set) var loadedSections: [ListSection] = []
    /// What shows now, by position in ``loadedSections``.
    private(set) var shown: [HostFilter.Shown] = []
    private(set) var emptyState: EmptyState?
    /// The banner from the last load.
    private(set) var notice: Notice?
    private(set) var nextPage: ListPageToken?
    /// True once a load applied.
    private(set) var hasLoaded = false
    /// Loads that applied.
    private(set) var loadCount = 0
    /// The reason of every load started, next pages included.
    private(set) var loadReasons: [LoadReason] = []

    private let pageEmptyState: EmptyState?
    private let preferences: HostPreferences?
    private let rememberKey: String
    private var hostFilter = HostFilter()
    private var index: (any FuzzyIndex)?
    private var generation = 0
    private var loadedGeneration = 0
    private var loadedSettings: [SettingStorage] = []
    private var loadTask: Task<Void, Never>?
    private var reloadPending = false
    private var nextPageTask: (token: Int, task: Task<Void, Never>)?
    private var nextPageTokenCounter = 0
    private var refreshTask: Task<Void, Never>?
    /// When the scheduled refresh is due, and the query it is for.
    private var refreshDue: (date: Date, query: String)?
    private var watchers: [Task<Void, Never>] = []
    /// True while the panel is hidden with this page on top.
    private(set) var isPanelHidden = false
    /// A reload was asked for while the panel was hidden.
    private var reloadWhenShown = false

    /// - Parameters:
    ///   - rememberKey: Names the page for a dropdown that remembers its selection.
    init(
        source: any ListSource, origin: RunOrigin, initialQuery: String, filter: FilterDropdown?,
        emptyState: EmptyState?, preferences: HostPreferences?, rememberKey: String
    ) {
        self.source = source
        self.origin = origin
        self.preferences = preferences
        self.rememberKey = rememberKey
        query = initialQuery
        pageEmptyState = emptyState
        dropdown = filter
        if let filter {
            let remembered = filter.remembersSelection ? preferences?.filterSelection(storageKey(filter)) : nil
            filterID =
                remembered.flatMap { id in filter.options.contains { $0.id == id } ? id : nil } ?? filter.defaultID
        }
    }

    var hostFilters: Bool { source.filtering == .host }

    /// True while the first load has not applied or a load is running.
    var isLoading: Bool { loadTask != nil }

    /// True while the source says it is busy with work of its own, such as a read that ends with
    /// a change signal.
    var sourceIsBusy: Bool { (source as? any BusySource)?.isBusy ?? false }

    // MARK: Lifecycle

    /// The page reached the top: listens for changes, and loads when it never did or when its data
    /// changed while it was covered. While the panel is hidden it waits for ``panelDidShow()``. A
    /// source that adopts ``PageEvents`` hears ``PageEvents/pageWillShowAgain(_:)`` first, except
    /// on the first push, so a signal it sends there costs one load.
    func appear() {
        guard !isPanelHidden else { return }
        if hasLoaded { pageEvents?.pageWillShowAgain(.returned) }
        startWatching()
        if !hasLoaded && loadTask == nil {
            load(.open)
        } else if isStale {
            load(.reload)
        }
    }

    /// The page was covered: stops listening. A load already running finishes.
    func disappear() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
    }

    /// The panel closed with this page on top: stops listening and holds the refresh timer. A load
    /// already running finishes.
    func panelDidHide() {
        guard !isPanelHidden else { return }
        isPanelHidden = true
        disappear()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// The panel opened with this page on top: listens again and loads once when the source
    /// changed, a reload was asked for, or the refresh came due while the panel was hidden. A
    /// refresh not yet due waits for the rest of its time.
    func panelDidShow() {
        guard isPanelHidden else { return }
        isPanelHidden = false
        // Before listening, so a signal the source sends here is seen once, as a stale load.
        if hasLoaded { pageEvents?.pageWillShowAgain(.panelOpened) }
        startWatching()
        let wantsReload = reloadWhenShown
        reloadWhenShown = false
        if !hasLoaded && loadTask == nil {
            load(.open)
        } else if wantsReload || isStale {
            load(.reload)
        } else if let due = refreshDue, loadTask == nil {
            let now = origin.feature.clock.now
            if query != due.query {
                refreshDue = nil
            } else if now >= due.date {
                refreshDue = nil
                load(.refresh)
            } else {
                scheduleRefresh(after: .milliseconds(Int64(due.date.timeIntervalSince(now) * 1000)))
            }
        }
    }

    /// The panel closed while the page was anywhere in the stack: tells a source that adopts
    /// ``PageEvents``.
    func panelDidClose() {
        pageEvents?.panelDidClose()
    }

    private var pageEvents: (any PageEvents)? { source as? any PageEvents }

    /// The page was popped: cancels everything.
    func close() {
        disappear()
        // Nothing that is still loading may apply to a closed page.
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        nextPageTask?.task.cancel()
        nextPageTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        reloadPending = false
    }

    // MARK: Input

    /// The search text changed: filters at once under host filtering, loads under custom filtering.
    func setQuery(_ text: String) {
        query = text
        refreshTask?.cancel()
        if hostFilters {
            applyFilter()
            onChange?(.filtered)
        } else {
            load(.query)
        }
    }

    /// The user picked a dropdown option.
    func setFilter(_ optionID: String) {
        filterID = optionID
        if let dropdown, dropdown.remembersSelection {
            preferences?.setFilterSelection(optionID, key: storageKey(dropdown))
        }
        load(.filter)
    }

    /// Loads again, as after a change signal or ``ActionContext/reload()``. While the panel is
    /// hidden it loads when the panel shows again.
    func reload() {
        guard !isPanelHidden else {
            reloadWhenShown = true
            return
        }
        load(.reload)
    }

    /// The row at a position in the loaded sections.
    func row(section: Int, row: Int) -> Row? {
        guard loadedSections.indices.contains(section), loadedSections[section].rows.indices.contains(row) else {
            return nil
        }
        return loadedSections[section].rows[row]
    }

    /// The shown sections as Kit sections, for tests and inspection.
    var sections: [ListSection] {
        shown.map { item in
            var section = loadedSections[item.section]
            section.rows = item.rows.map { loadedSections[item.section].rows[$0] }
            return section
        }
    }

    /// The number of rows shown.
    var shownCount: Int { shown.reduce(0) { $0 + $1.rows.count } }

    // MARK: Loading

    private var isStale: Bool {
        (source.changes?.generation ?? 0) != loadedGeneration
            || source.reloadsOnSettings.map(origin.feature.settings.storage(of:)) != loadedSettings
    }

    /// Loads for a reason. A newer load cancels an older one, and only the newest applies. A reload
    /// while a load runs waits for it and runs once after it.
    func load(_ reason: LoadReason) {
        if reason == .reload, loadTask != nil {
            reloadPending = true
            return
        }
        reloadPending = false
        loadTask?.cancel()
        cancelNextPage()
        generation += 1
        let current = generation
        let source = source
        let request = ListRequest(query: hostFilters ? "" : query, filter: filterID, reason: reason)
        let debounce: Duration? =
            if case .custom(let delay) = source.filtering, reason == .query, delay > .zero { delay } else { nil }
        loadReasons.append(reason)
        loadedGeneration = source.changes?.generation ?? 0
        loadedSettings = source.reloadsOnSettings.map(origin.feature.settings.storage(of:))
        let clock = origin.feature.clock
        let fuzzy = origin.feature.fuzzyIndex
        loadTask = Task { [weak self] in
            do {
                if let debounce { try await clock.sleep(for: debounce) }
                self?.setLoading(true, generation: current)
                let result = try await source.load(request)
                try Task.checkCancellation()
                guard let self, current == generation else { return }
                await apply(result, generation: current, fuzzy: fuzzy)
            } catch is CancellationError {
                return
            } catch {
                guard let self, current == generation else { return }
                onError?(error)
            }
            self?.finishLoad(generation: current)
        }
    }

    private func finishLoad(generation current: Int) {
        guard current == generation else { return }
        loadTask = nil
        setLoading(false, generation: current)
        if reloadPending {
            reloadPending = false
            if isPanelHidden { reloadWhenShown = true } else { load(.reload) }
        }
    }

    private func setLoading(_ loading: Bool, generation current: Int) {
        guard current == generation else { return }
        onLoading?(loading)
    }

    private func apply(_ result: ListResult, generation current: Int, fuzzy: any FuzzyIndexService) async {
        if let replacement = result.filter {
            dropdown = replacement
            if !replacement.options.contains(where: { $0.id == filterID }), filterID != replacement.defaultID {
                filterID = replacement.defaultID
                onDropdownChange?()
                loadTask = nil
                load(.filter)
                return
            }
            onDropdownChange?()
        }
        if hostFilters {
            let (entries, positions) = HostFilter.entries(for: result.sections)
            let built = await fuzzy.makeIndex(entries)
            guard current == generation, !Task.isCancelled else { return }
            index = built
            hostFilter.positions = positions
        }
        loadedSections = result.sections
        emptyState = result.emptyState ?? pageEmptyState
        notice = result.notice
        nextPage = hostFilters ? nil : result.nextPage
        applyFilter()
        hasLoaded = true
        loadCount += 1
        onChange?(.loaded)
        scheduleRefresh(after: result.refreshAfter)
    }

    /// True when a next page exists and none is loading.
    var canLoadNextPage: Bool { !hostFilters && nextPage != nil && nextPageTask == nil && loadTask == nil }

    /// Loads the next page of a paged result and appends it.
    func loadNextPage() {
        guard canLoadNextPage, let token = nextPage else { return }
        let source = source
        let request = ListRequest(query: query, filter: filterID, page: token, reason: .nextPage)
        let current = generation
        loadReasons.append(.nextPage)
        nextPageTokenCounter += 1
        let mine = nextPageTokenCounter
        let task = Task { [weak self] in
            do {
                let result = try await source.load(request)
                try Task.checkCancellation()
                guard let self, current == generation, nextPageTask?.token == mine else { return }
                nextPageTask = nil
                for section in result.sections {
                    if let index = loadedSections.firstIndex(where: { $0.id == section.id }) {
                        loadedSections[index].rows += section.rows
                    } else {
                        loadedSections.append(section)
                    }
                }
                nextPage = result.nextPage
                applyFilter()
                onChange?(.appended)
            } catch {
                guard let self, nextPageTask?.token == mine else { return }
                nextPageTask = nil
                if !(error is CancellationError) { onError?(error) }
            }
        }
        nextPageTask = (mine, task)
    }

    private func cancelNextPage() {
        nextPageTask?.task.cancel()
        nextPageTask = nil
    }

    private func scheduleRefresh(after delay: Duration?) {
        refreshTask?.cancel()
        refreshTask = nil
        refreshDue = nil
        guard let delay else { return }
        let queryAtLoad = query
        let clock = origin.feature.clock
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) * 1e-18
        refreshDue = (clock.now.addingTimeInterval(seconds), queryAtLoad)
        // Hidden: the timer waits for the panel, and panelDidShow() loads when it came due.
        guard !isPanelHidden else { return }
        refreshTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, query == queryAtLoad else { return }
            refreshDue = nil
            load(.refresh)
        }
    }

    private func startWatching() {
        guard watchers.isEmpty else { return }
        if let signal = source.changes {
            let stream = signal.stream()
            watchers.append(
                Task { [weak self] in
                    for await _ in stream { self?.load(.reload) }
                })
        }
        let keys = source.reloadsOnSettings
        if !keys.isEmpty {
            let changes = origin.feature.settings.changes(ofAny: keys)
            watchers.append(
                Task { [weak self] in
                    for await _ in changes { self?.load(.reload) }
                })
        }
    }

    // MARK: Filtering

    private func applyFilter() {
        guard hostFilters else {
            var shown: [HostFilter.Shown] = []
            for (index, section) in loadedSections.enumerated()
            where section.isVisible(forQuery: query) && !section.rows.isEmpty {
                shown.append(HostFilter.Shown(section: index, rows: Array(section.rows.indices), highlights: []))
            }
            self.shown = shown
            return
        }
        var matches: [FuzzyMatch]?
        if !query.isEmpty, let index {
            let query = query
            matches = meter?.measureSearch { index.search(query, limit: Int.max) } ?? index.search(query, limit: .max)
        }
        shown = hostFilter.filter(loadedSections, query: query, matches: matches)
    }

    private func storageKey(_ dropdown: FilterDropdown) -> String {
        origin.featureID + "/" + rememberKey + "/" + dropdown.title
    }
}
