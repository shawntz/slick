import AppKit
import Kit
import KitHosting
import LauncherUI

/// A form a command pushed, drawn by LauncherUI's ``FormView``.
///
/// Every Kit field kind maps to a form row. Command-Return submits, from a field or from the
/// search field: the page checks ``FormPage/requires`` through the run pipeline's permission card,
/// then the required fields at once, then ``FormPage/validate``, and shows each ``FieldError``
/// under its field. The first field with an error takes focus, with the error's range selected.
/// Editing a field clears its error. When the values are fine, ``FormPage/submit`` runs through the
/// pipeline like any action, so its outcome, its toasts and its errors behave the same. File fields
/// choose through ``FileDialogService``. An application field picks from the apps root search
/// knows, in a menu inside the panel, loaded when the page appears. Text fields colour `{...}`
/// placeholders when the field asks for it, and tag fields offer their suggestions.
@MainActor public final class FormPageController: PageController {
    public let page: FormPage
    public let origin: RunOrigin
    public let contentView = PageContentView()
    public let form = FormView()

    /// The errors shown now, by field ID.
    public private(set) var errors: [String: FieldError] = [:]
    /// True from Command-Return until the submit handler finished or validation failed.
    public private(set) var isSubmitting = false
    /// Submit handlers started, for tests.
    public private(set) var submissions = 0
    /// The range selected for the last error, in UTF-16 offsets, for tests.
    public private(set) var selectedErrorRange: NSRange?

    private weak var host: (any PageHost)?
    private var items: [FormItem]
    private var chosenFiles: [String: [URL]] = [:]
    private var lastFocusedID: String?
    private var isClosed = false
    private var appsTask: Task<Void, Never>?

    public init(page: FormPage, origin: RunOrigin) {
        self.page = page
        self.origin = origin
        items = page.fields.map(Self.item)
        form.apply(FormContent(items: items))
        contentView.show(form)
        form.onSubmit = { [weak self] in self?.submit() }
        form.onCancel = { [weak self] in
            guard let self else { return }
            host?.popPage(self)
        }
        form.onChooseFile = { [weak self] id in self?.choose(id) }
        form.onChange = { [weak self] id, _ in self?.fieldDidChange(id) }
    }

    public var title: String? { page.title }
    public var isBusy: Bool { isSubmitting }
    public var featureID: String? { origin.featureID }
    public var searchPlaceholder: String { "" }
    public var query: String { "" }

    // MARK: Lifecycle

    public func pageDidAppear(in host: any PageHost) {
        self.host = host
        // The first field at first, then the field that had focus when a page covered the form.
        form.focus(lastFocusedID)
        loadApps(host)
    }

    public func pageDidDisappear() {
        lastFocusedID = form.focusedID
    }

    public func pageWillClose() {
        isClosed = true
        appsTask?.cancel()
        appsTask = nil
    }

    /// The apps an application field offers, once loaded. Empty until then, for tests.
    public private(set) var applications: [MenuOption] = []

    /// Loads the apps root search knows, from the catalog of the feature that owns the `app`
    /// namespace, once, and puts them in every application field. An app's icon is looked up, never
    /// read from disk; one that is not ready draws without an icon.
    private func loadApps(_ host: any PageHost) {
        guard appsTask == nil, applications.isEmpty,
            page.fields.contains(where: { if case .application = $0.kind { true } else { false } })
        else { return }
        let sources = host.runtime.enabledFeatures.flatMap(\.catalogSources).filter {
            $0.namespace == ItemID.ReservedNamespace.app
        }
        guard !sources.isEmpty else { return }
        let mapper = host.rowMapper
        appsTask = Task { [weak self] in
            var rows: [Row] = []
            for source in sources {
                if let loaded = try? await source.rows() { rows += loaded }
            }
            guard let self, !isClosed, !Task.isCancelled else { return }
            var seen: Set<String> = []
            let apps =
                rows
                .filter { $0.id.namespace == ItemID.ReservedNamespace.app && seen.insert($0.id.key).inserted }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { MenuOption(id: $0.id.key, title: $0.title, icon: mapper.cardIcon($0.icon)) }
            applications = apps
            for index in items.indices {
                if case .application(let placeholder, _) = items[index].kind {
                    items[index].kind = .application(placeholder: placeholder, apps: apps)
                }
            }
            form.apply(FormContent(items: items))
        }
    }

    // MARK: Input

    public func queryDidChange(_ text: String) {}
    public func moveSelection(_ move: SelectionMove) -> Bool { false }

    public func handle(_ command: QueryCommand) -> Bool {
        guard case .submit(let modifiers) = command else { return false }
        if modifiers == .command {
            submit()
        } else {
            form.focus(nil)
        }
        return true
    }

    public var target: ActionTarget? {
        let entry = ActionEntry(
            title: page.submitTitle, icon: .symbol("checkmark.circle"), shortcut: .secondaryAction,
            kind: .custom { [weak self] in self?.submit() })
        return ActionTarget(
            row: nil, entries: [entry], featureID: origin.featureID, context: origin.feature, launch: .page, query: "")
    }

    // MARK: Values

    /// The values as Kit sees them, by field ID.
    public var values: FormValues {
        var values = FormValues()
        let shown = form.values
        for field in page.fields {
            guard let value = shown[field.id] else { continue }
            switch (field.kind, value) {
            case (.files, .text(let text)): values[field.id] = .files(files(for: field.id, text: text))
            case (_, .text(let text)): values[field.id] = .text(text)
            case (_, .bool(let flag)): values[field.id] = .bool(flag)
            case (_, .date(let date)): values[field.id] = date.map(Kit.FormValue.date)
            case (_, .option(let id)): values[field.id] = id.map(Kit.FormValue.text)
            case (_, .tags(let tags)): values[field.id] = .strings(tags)
            case (_, .hotkey): break
            }
        }
        return values
    }

    /// Sets a field's value as if the user had entered it, for scenarios and tests.
    public func fill(_ id: String, _ value: Kit.FormValue) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch value {
        case .text(let text): items[index].value = .text(text)
        case .bool(let flag): items[index].value = .bool(flag)
        case .date(let date): items[index].value = .date(date)
        case .strings(let strings): items[index].value = .tags(strings)
        case .files(let urls):
            chosenFiles[id] = urls
            items[index].value = .text(Self.display(urls))
        }
        switch (items[index].kind, value) {
        case (.dropdown, .text(let option)), (.application, .text(let option)): items[index].value = .option(option)
        default: break
        }
        form.apply(FormContent(items: items))
        fieldDidChange(id)
    }

    // MARK: Submitting

    /// Checks permissions, required fields and the validator, then runs the submit handler.
    public func submit() {
        guard !isSubmitting, let host else { return }
        isSubmitting = true
        let values = values
        let pipeline = host.runtime.pipeline
        let page = page
        let origin = RunOrigin(featureID: origin.featureID, feature: origin.feature, launch: .page)
        Task { [weak self] in
            guard await pipeline.ensurePermissions(page.requires, featureID: origin.featureID) else {
                self?.isSubmitting = false
                return
            }
            var errors = page.missingRequiredFields(in: values)
            if errors.isEmpty, let validate = page.validate {
                if let self { host.page(self, isLoading: true) }
                errors = await validate(values)
                if let self { host.page(self, isLoading: false) }
            }
            guard let self, !isClosed else { return }
            show(errors)
            guard errors.isEmpty else {
                isSubmitting = false
                return
            }
            submissions += 1
            await pipeline.perform(key: "form." + page.title, origin: origin) { context in
                try await page.submit(values, context)
            }.value
            isSubmitting = false
        }
    }

    private func show(_ errors: [String: FieldError]) {
        self.errors = errors
        for index in items.indices { items[index].error = errors[items[index].id]?.message }
        form.apply(FormContent(items: items))
        guard let first = page.fields.first(where: { errors[$0.id] != nil }) else { return }
        form.focus(first.id)
        selectedErrorRange = nil
        guard let range = errors[first.id]?.range, let editor = form.window?.firstResponder as? NSTextView else {
            return
        }
        let length = (editor.string as NSString).length
        let start = min(max(0, range.lowerBound), length)
        let selection = NSRange(location: start, length: min(range.count, length - start))
        editor.setSelectedRange(selection)
        selectedErrorRange = selection
    }

    private func fieldDidChange(_ id: String) {
        guard errors[id] != nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        errors[id] = nil
        items[index].error = nil
        form.apply(FormContent(items: items))
    }

    // MARK: Files and apps

    private func choose(_ id: String) {
        guard let field = page.fields.first(where: { $0.id == id }) else { return }
        let dialogs = origin.feature.fileDialogs
        switch field.kind {
        case .files(let request):
            Task { [weak self] in
                let urls = await dialogs.chooseFiles(request)
                guard let self, !urls.isEmpty, !isClosed else { return }
                fill(id, .files(urls))
            }
        default:
            break
        }
    }

    private func files(for id: String, text: String) -> [URL] {
        if let chosen = chosenFiles[id], Self.display(chosen) == text { return chosen }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return [URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)]
    }

    nonisolated static func display(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: ", ")
    }

    // MARK: Mapping

    /// A Kit field as a form row.
    public nonisolated static func item(_ field: FormField) -> FormItem {
        let kind: FormItem.Kind
        var value: LauncherUI.FormValue?
        var highlightsPlaceholders = false
        var suggestions: [String] = []
        switch field.kind {
        case .text(let placeholder, let initial, let highlights):
            kind = .text(placeholder: placeholder ?? "")
            value = .text(initial)
            highlightsPlaceholders = highlights
        case .multiline(let placeholder, let initial, let highlights):
            kind = .multiline(placeholder: placeholder ?? "")
            value = .text(initial)
            highlightsPlaceholders = highlights
        case .password(let placeholder):
            kind = .secure(placeholder: placeholder ?? "")
        case .checkbox(let label, let initial):
            kind = .checkbox(label: label)
            value = .bool(initial)
        case .dropdown(let options, let initial):
            kind = .dropdown(options.map { MenuOption(id: $0.value, title: $0.title) })
            value = .option(initial ?? options.first?.value)
        case .date(let initial, let includesTime):
            kind = .date(includesTime: includesTime)
            value = .date(initial)
        case .files(let request):
            kind = .filePath(placeholder: request.title ?? "", buttonTitle: HostStrings.choose)
        case .tags(let offered, let initial):
            kind = .tags(placeholder: "")
            value = .tags(initial)
            suggestions = offered
        case .application(let initial):
            kind = .application(placeholder: HostStrings.applicationPlaceholder, apps: [])
            value = .option(initial)
        case .description(let text):
            kind = .description(text)
        case .separator:
            kind = .separator
        }
        var item = FormItem(id: field.id, label: field.title, kind: kind, value: value, info: field.info)
        item.highlightsPlaceholders = highlightsPlaceholders
        item.suggestions = suggestions
        return item
    }
}
