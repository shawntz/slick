import Foundation
import Kit

extension FeatureHarness {
    // MARK: - Pages

    /// The top page.
    public var page: PageState? { pages.last }
    /// The top page's visible sections.
    public var sections: [ListSection] { page?.sections ?? [] }
    /// The top page's visible rows.
    public var rows: [Row] { page?.rows ?? [] }
    /// The top page's selected row.
    public var selectedRow: Row? { page?.selectedRow }
    /// What the top detail page shows.
    public var detail: Detail? { page?.detail }

    /// Pushes a page and loads it, as the host does for ``ActionOutcome/push(_:)``.
    public func open(_ page: Page) async throws {
        isClosed = false
        let state = PageState(page)
        pages.append(state)
        if case .form(let form) = page { note(FeatureValidator.validate(form: form, manifest: F.manifest)) }
        try await load(state, reason: .open)
    }

    /// Loads the top page again, as the host does after a ``ChangeSignal``, a settings change or a
    /// reload.
    public func reloadPage() async throws {
        guard let state = page else { throw HarnessError.noPage }
        try await load(state, reason: .reload)
    }

    /// Loads the top list again as the host does when ``ListResult/refreshAfter`` passes.
    public func refresh() async throws {
        guard let state = page else { throw HarnessError.noPage }
        try await load(state, reason: .refresh)
    }

    /// Loads the next page of a paged result and appends it, as the host does when the user scrolls
    /// near the end. Returns false when there was no next page.
    @discardableResult
    public func loadNextPage() async throws -> Bool {
        guard let state = page, let source = state.listSource else { throw HarnessError.wrongPage(expected: "list") }
        guard let token = state.nextPage else { return false }
        let result = try await source.load(
            ListRequest(query: state.query, filter: state.filter, page: token, reason: .nextPage))
        for section in result.sections {
            if let index = state.loadedSections.firstIndex(where: { $0.id == section.id }) {
                state.loadedSections[index].rows += section.rows
            } else {
                state.loadedSections.append(section)
            }
        }
        state.nextPage = result.nextPage
        state.sections = state.loadedSections.filter { $0.isVisible(forQuery: state.query) && !$0.rows.isEmpty }
        state.keepSelectionVisible()
        return true
    }

    /// Types into the search field of the top page.
    public func setQuery(_ query: String) async throws {
        guard let state = page else { throw HarnessError.noPage }
        state.query = query
        try await applyQuery(state)
    }

    /// Picks an option in the top page's filter dropdown and loads again.
    public func setFilter(_ optionID: String) async throws {
        guard let state = page else { throw HarnessError.noPage }
        state.filter = optionID
        try await load(state, reason: .filter)
    }

    /// Selects a visible row by ID, in the first section that shows it.
    public func select(_ id: ItemID) throws {
        guard let state = page, state.rows.contains(where: { $0.id == id }) else {
            throw HarnessError.noSuchRow(id.rawValue)
        }
        state.select(id)
    }

    /// Selects the first visible row with this title.
    public func select(title: String) throws {
        guard let state = page, let row = state.rows.first(where: { $0.title == title }) else {
            throw HarnessError.noSuchRow(title)
        }
        state.select(row.id)
    }

    /// Selects the visible row at a position, counting across sections.
    public func select(at index: Int) throws {
        guard let state = page, state.rows.indices.contains(index) else { throw HarnessError.noSuchRow("#\(index)") }
        var remaining = index
        for section in state.sections {
            if remaining < section.rows.count {
                state.selectedID = section.rows[remaining].id
                state.selectedSection = section.id
                return
            }
            remaining -= section.rows.count
        }
    }

    /// Goes back one page.
    public func pop() {
        _ = pages.popLast()
    }

    /// The detail pane's content for the selected row.
    public func loadDetail() async throws -> Detail? {
        guard let state = page, let source = state.listSource else { throw HarnessError.wrongPage(expected: "list") }
        guard let row = state.selectedRow else { return nil }
        return try await source.detail(for: row)
    }

    /// Sends follow-up text to the top detail page and applies the answer.
    public func followUp(_ text: String) async throws {
        guard let state = page, case .detail(let detailPage) = state.page else {
            throw HarnessError.wrongPage(expected: "detail")
        }
        for try await update in detailPage.source.followUp(text) {
            state.detail.apply(update)
        }
    }

    // MARK: - Actions

    /// The actions the action panel would show: the selected row's, the empty state's when nothing is
    /// selected, or the detail page's for what it shows.
    public func actions() -> [Action] {
        guard let state = page else { return [] }
        if case .detail(let detailPage) = state.page { return shown(detailPage.source.actions(for: state.detail)) }
        if let source = state.listSource, let row = state.selectedRow { return shown(source.actions(for: row)) }
        return shown(state.emptyState?.actions ?? [])
    }

    /// Runs one of ``actions()`` by ID or title.
    @discardableResult
    public func perform(_ actionID: String) async throws -> ActionOutcome {
        try await perform(try action(actionID, in: actions()), row: selectedRow)
    }

    /// Runs the action Return runs.
    @discardableResult
    public func performPrimary() async throws -> ActionOutcome {
        guard let action = actions().primary else { throw HarnessError.noSuchAction("primary") }
        return try await perform(action, row: selectedRow)
    }

    /// Runs the action Command-Return runs.
    @discardableResult
    public func performSecondary() async throws -> ActionOutcome {
        guard let action = actions().secondary else { throw HarnessError.noSuchAction("secondary") }
        return try await perform(action, row: selectedRow)
    }

    /// The entries of a submenu among ``actions()``.
    public func submenu(_ actionID: String) async throws -> [Action] {
        try await submenu(actionID, in: actions(), row: selectedRow, query: page?.query ?? "")
    }

    /// The entries of a submenu among any actions, such as a root row's or a universal action's.
    public func submenu(
        _ actionID: String, in actions: [Action], row: Row?, query: String = "", launch: LaunchSource = .page
    ) async throws -> [Action] {
        let action = try action(actionID, in: actions)
        guard case .submenu(let load) = action.kind else { throw HarnessError.notASubmenu(action.id) }
        return shown(await load(makeContext(query: query, launch: launch, row: row)))
    }

    /// Runs any action as the host does: checks its permissions, asks its confirmation, runs it
    /// under its ``RunPolicy`` and applies the outcome. Returns `.keepOpen` without running when the
    /// confirmation is declined.
    @discardableResult
    public func perform(_ action: Action, row: Row?, query: String? = nil, launch: LaunchSource = .page)
        async throws -> ActionOutcome
    {
        guard case .run(let handler) = action.kind else { throw HarnessError.isSubmenu(action.id) }
        isClosed = false
        return try await execute(
            requires: action.requires, confirmation: action.confirmation, policy: action.runPolicy,
            key: "action." + action.id,
            context: makeContext(query: query ?? page?.query ?? "", launch: launch, row: row),
            handler: handler)
    }

    // MARK: - Forms

    /// Sets a form field's value.
    public func fill(_ fieldID: String, _ value: FormValue) throws {
        guard let state = page, case .form = state.page else { throw HarnessError.wrongPage(expected: "form") }
        state.formValues[fieldID] = value
    }

    /// Sets a text field's value.
    public func fill(_ fieldID: String, text: String) throws {
        try fill(fieldID, .text(text))
    }

    /// Submits the top form: permissions, required fields, then `validate`, then `submit`.
    @discardableResult
    public func submit() async throws -> ActionOutcome {
        guard let state = page, case .form(let form) = state.page else {
            throw HarnessError.wrongPage(expected: "form")
        }
        try await checkPermissions(form.requires)
        let values = state.formValues
        var errors = form.missingRequiredFields(in: values)
        if errors.isEmpty, let validate = form.validate {
            errors = await validate(values)
        }
        state.formErrors = errors
        guard errors.isEmpty else { throw HarnessError.invalidForm(errors) }
        return try await execute(
            requires: [], confirmation: nil, policy: .serial, key: "form." + form.title,
            context: makeContext(query: "", launch: .page, row: nil)
        ) { context in
            try await form.submit(values, context)
        }
    }
}
