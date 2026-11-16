import Foundation
import Kit
import KitStorage
import KitTemplates
import os

/// Quicklinks: open a site, a search or a deep link by typing its name, with up to three values
/// typed in the search bar, and search the web when nothing else matches.
///
/// - Quicklinks live in one JSON file in the feature's data folder, written atomically. The file is
///   watched, so an edit made by hand applies at once.
/// - About thirty web searches are built in. The user can edit, turn off and delete them, and
///   restore them from settings.
/// - Quicklinks without arguments join root search's catalog through `QuicklinkCatalog`. Quicklinks with
///   arguments are commands with fields in the search bar. Those that take the typed text can be
///   fallbacks; the default search engine is the first.
/// - A typed web address offers to open it, through `AddressProvider`, a strict instant provider.
/// - Universal actions search the web for selected text and open a selected link.
///
/// Every link opens through Kit's workspace service. The feature makes no network request: icons
/// are Kit's favicon icons, which the host resolves from its own cache.
public final class QuicklinksFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "quicklinks", name: Strings.featureName, icon: .symbol("link"), summary: Strings.featureSummary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.selectionReason)])

    /// The file's name in the data folder.
    static let fileName = "quicklinks.json"

    let context: FeatureContext
    /// Sent after the quicklinks change, the file's readability changes, or a setting that shapes
    /// the declarations changes. The host reads the declarations again; lists and the catalog reload.
    let changes = ChangeSignal()
    /// The quicklinks as last read or saved.
    private(set) var file = QuicklinkFile.defaults
    /// Each quicklink with its parsed link, in file order.
    private(set) var entries: [QuicklinkEntry] = []
    /// Set while the file on disk cannot be read. Saving waits until it can, so the file is never
    /// overwritten with a list the user did not see.
    private(set) var fileProblem: String?

    private var entriesByID: [String: QuicklinkEntry] = [:]
    /// The quicklinks that are on and take the typed text, in file order.
    private(set) var searchEngines: [QuicklinkEntry] = []
    private let store: JSONFileStore<QuicklinkFile>
    private var listening: [Task<Void, Never>] = []
    private var reading: Task<Void, Never>?

    private lazy var catalog = QuicklinkCatalog(feature: self)
    private lazy var addressProvider = AddressProvider(feature: self)
    lazy var browseList = QuicklinkList(feature: self, purpose: .browse)
    lazy var editList = QuicklinkList(feature: self, purpose: .edit)
    lazy var actions = QuicklinkActions(feature: self)
    lazy var forms = QuicklinkForms(feature: self)

    /// Does no I/O: the store is a path until ``activate()`` reads it.
    public init(context: FeatureContext) {
        self.context = context
        store = JSONFileStore(url: context.storage.dataFile(Self.fileName))
        apply(QuicklinkIndex(file))
    }

    /// Reads the file, writing the built-in searches on first launch, then watches the file and the
    /// settings.
    public func activate() async {
        // A second activation without a deactivation in between replaces the first one's work.
        for task in listening { task.cancel() }
        await readFile(isLaunch: true)
        // Subscribe before starting the tasks that read, so no change in between is lost.
        let fileChanges = context.fileWatcher.watch([context.storage.dataDirectory])
        let settingChanges = context.settings.changes(ofAny: QuicklinksSettings.all)
        listening = [
            Task { [weak self] in
                for await _ in fileChanges { await self?.reload() }
            },
            Task { [weak self] in
                for await _ in settingChanges { self?.changes.send() }
            },
        ]
    }

    public func deactivate() async {
        for task in listening { task.cancel() }
        listening = []
    }

    // MARK: - Declarations

    public var declarationChanges: ChangeSignal? { changes }

    public var commands: [Command] {
        let engineID = defaultEngine?.id
        var linkEntries = entries.filter { $0.isEnabled && !$0.arguments.isEmpty }
        // The default search engine is the first fallback.
        if let index = linkEntries.firstIndex(where: { $0.id == engineID }) {
            linkEntries.insert(linkEntries.remove(at: index), at: 0)
        }
        let linkCommands = linkEntries.map { entry in
            QuicklinkCommand.make(entry, offersFallback: offersFallback(entry, engineID: engineID), feature: self)
        }
        return managementCommands + linkCommands
    }

    public var catalogSources: [any CatalogSource] { [catalog] }

    public var liveProviders: [LiveProvider] {
        context.settings[QuicklinksSettings.detectsAddresses] ? [.instant(addressProvider)] : []
    }

    public var universalActions: [UniversalActionProvider] {
        [
            .text { [unowned self] text in actions.universalActions(forText: text) },
            .url { [unowned self] url in actions.universalActions(forURL: url) },
        ]
    }

    public var settingsPane: SettingsPane? {
        QuicklinksSettingsPane.make(feature: self)
    }

    public var status: FeatureStatus? {
        guard fileProblem != nil else { return nil }
        return FeatureStatus(.warning, Strings.statusUnreadable, message: Strings.statusUnreadableMessage)
    }

    private var managementCommands: [Command] {
        [
            Command(
                id: "search", title: Strings.searchQuicklinks, icon: Self.manifest.icon,
                keywords: Strings.searchKeywords
            ) { [unowned self] _ in
                .push(.list(browseList.page()))
            },
            Command(
                id: "create", title: Strings.createQuicklink, icon: .symbol("plus"), keywords: Strings.createKeywords
            ) { [unowned self] context in
                .push(.form(forms.create(link: context.arguments["link"] ?? "")))
            },
            Command(id: "edit", title: Strings.editQuicklink, icon: .symbol("pencil")) { [unowned self] context in
                if let id = context.arguments["id"], let entry = entry(id: id) {
                    return .push(.form(forms.edit(entry.quicklink)))
                }
                return .push(.list(editList.page()))
            },
            // Import and export open a file dialog, which a web page must never be able to raise, so
            // neither runs from a link.
            Command(
                id: "import", title: Strings.importQuicklinks, subtitle: Strings.importSubtitle,
                icon: .symbol("square.and.arrow.down"), keywords: Strings.importKeywords, allowsDeepLinks: false
            ) { [unowned self] context in
                try await importFromFile(context: context)
            },
            Command(
                id: "export", title: Strings.exportQuicklinks, icon: .symbol("square.and.arrow.up"),
                keywords: Strings.exportKeywords, allowsDeepLinks: false
            ) { [unowned self] context in
                try await exportToFile(context: context)
            },
        ]
    }

    // MARK: - What the sources and actions read

    func entry(id: String) -> QuicklinkEntry? {
        entriesByID[id]
    }

    /// The search engine the settings name, or the first that can stand in for it. Looked up by
    /// ID, so it costs the same with fifty thousand quicklinks.
    var defaultEngine: QuicklinkEntry? {
        func engine(_ id: String) -> QuicklinkEntry? {
            guard let entry = entriesByID[id], entry.isEnabled, entry.takesQuery else { return nil }
            return entry
        }
        return engine(context.settings[QuicklinksSettings.defaultSearch]) ?? engine(DefaultSearches.defaultEngineID)
            ?? searchEngines.first
    }

    /// True when root offers the quicklink when nothing else matches. See
    /// ``QuicklinkEntry/offersFallback(engineID:fallbacksOn:)``.
    func offersFallback(_ entry: QuicklinkEntry, engineID: String?) -> Bool {
        entry.offersFallback(engineID: engineID, fallbacksOn: context.settings[QuicklinksSettings.offersFallbacks])
    }

    /// The quicklinks file, for settings to reveal.
    var fileURL: URL { store.url }

    // MARK: - Opening

    /// Renders a quicklink with the values typed for it and opens the result. A fallback or a Tab
    /// handoff fills the first argument with the typed text when the host has not.
    func open(
        _ entry: QuicklinkEntry, context: ActionContext, values: [String: String]? = nil, app: String? = nil
    ) async throws -> ActionOutcome {
        var values = values ?? context.arguments.values
        if context.launch == .fallback || context.launch == .tabFromRoot, let first = entry.arguments.first,
            (values[first.key] ?? "").isEmpty, !context.query.isEmpty
        {
            values[first.key] = context.query
        }
        let url = try await link(for: entry, context: context, values: values)
        try await open(url, with: app ?? entry.quicklink.openWith, context: context)
        return .close()
    }

    /// The quicklink's link rendered with these values. Throws an ``ActionFailure`` the user can read.
    func link(for entry: QuicklinkEntry, context: ActionContext, values: [String: String]) async throws -> URL {
        let environment = TemplateEnvironment(context: context.feature, arguments: values)
        do {
            return try await entry.template.url(in: environment)
        } catch let error as LinkError {
            throw ActionFailure(Strings.linkNotValid(entry.quicklink.name), message: error.message)
        }
    }

    /// Opens a link through the workspace service, with an app when one is named.
    func open(_ url: URL, with app: String?, context: ActionContext) async throws {
        do {
            if let app, !app.isEmpty {
                try await context.workspace.open([url], withApplication: app)
            } else {
                try await context.workspace.open(url)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionFailure(Strings.couldNotOpen, message: url.absoluteString)
        }
    }

    // MARK: - Changing the quicklinks

    /// Adds a quicklink, or replaces the one with the same ID.
    func upsert(_ quicklink: Quicklink) async throws {
        var next = file
        if let index = next.quicklinks.firstIndex(where: { $0.id == quicklink.id }) {
            next.quicklinks[index] = quicklink
        } else {
            next.quicklinks.append(quicklink)
        }
        try await save(next)
    }

    /// Deletes a quicklink. A deleted built-in search is remembered, so it stays deleted.
    func remove(id: String) async throws {
        var next = file
        guard let index = next.quicklinks.firstIndex(where: { $0.id == id }) else { return }
        let removed = next.quicklinks.remove(at: index)
        if removed.isBuiltIn, DefaultSearches.quicklink(id: removed.id) != nil,
            !next.removedDefaults.contains(removed.id)
        {
            next.removedDefaults.append(removed.id)
        }
        try await save(next)
    }

    func setEnabled(_ isEnabled: Bool, id: String) async throws {
        var next = file
        guard let index = next.quicklinks.firstIndex(where: { $0.id == id }) else { return }
        next.quicklinks[index].isEnabled = isEnabled
        try await save(next)
    }

    /// Brings back every built-in search as it first was. The user's own quicklinks stay.
    func restoreDefaults() async throws {
        var next = file
        next.removedDefaults = []
        for builtIn in DefaultSearches.all {
            if let index = next.quicklinks.firstIndex(where: { $0.id == builtIn.id }) {
                // A quicklink of the user's own that happens to share the ID stays as it is.
                if next.quicklinks[index].isBuiltIn { next.quicklinks[index] = builtIn }
            } else {
                next.quicklinks.append(builtIn)
            }
        }
        try await save(next)
    }

    /// Adds imported quicklinks.
    func add(_ quicklinks: [Quicklink]) async throws {
        guard !quicklinks.isEmpty else { return }
        var next = file
        next.quicklinks += quicklinks
        try await save(next)
    }

    private func save(_ next: QuicklinkFile) async throws {
        guard fileProblem == nil else {
            throw ActionFailure(Strings.fileUnreadableTitle, message: Strings.fileUnreadableMessage)
        }
        let index = await QuicklinkIndex.build(next)
        try await store.save(next)
        apply(index)
        changes.send()
    }

    /// Takes an index made off the main thread. Assigning is all the main thread does.
    private func apply(_ index: QuicklinkIndex) {
        file = index.file
        entries = index.entries
        entriesByID = index.byID
        searchEngines = index.searchEngines
    }

    // MARK: - Reading the file

    /// Reads the file again after it changed on disk. Reads run one after another, so the last one
    /// wins.
    private func reload() async {
        let previous = reading
        let task = Task { [weak self] in
            await previous?.value
            await self?.readFile(isLaunch: false)
        }
        reading = task
        await task.value
    }

    private func readFile(isLaunch: Bool) async {
        let hadProblem = fileProblem != nil
        do {
            if let stored = try await store.load() {
                fileProblem = nil
                let current = isLaunch || hadProblem ? nil : file
                guard let index = await QuicklinkIndex.read(stored, unlessSameAs: current) else { return }
                apply(index)
            } else if isLaunch {
                fileProblem = nil
                apply(await QuicklinkIndex.build(.defaults))
                await writeFirstFile()
            } else {
                // Deleted while running: start again from the built-in searches. The next change
                // writes the file.
                fileProblem = nil
                guard hadProblem || file != .defaults else { return }
                apply(await QuicklinkIndex.build(.defaults))
            }
        } catch {
            context.log.error("Could not read the quicklinks file: \(error.localizedDescription, privacy: .private)")
            fileProblem = error.localizedDescription
            guard isLaunch || !hadProblem else { return }
        }
        changes.send()
    }

    /// Writes the built-in searches on first launch, so the file exists for the user to find.
    private func writeFirstFile() async {
        do {
            try await store.save(file)
        } catch {
            context.log.error("Could not write the quicklinks file: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Import and export

    /// Asks for a file, then shows what importing it would do. Nothing is saved until the user
    /// confirms on that page.
    private func importFromFile(context: ActionContext) async throws -> ActionOutcome {
        // Say so before the dialog, so nobody picks a file for nothing.
        guard fileProblem == nil else {
            throw ActionFailure(Strings.fileUnreadableTitle, message: Strings.fileUnreadableMessage)
        }
        let request = OpenDialogRequest(title: Strings.importDialogTitle, allowedTypes: ["json", "plist"])
        guard let url = await context.fileDialogs.chooseFiles(request).first else { return .keepOpen }
        let incoming = try await QuicklinkExchange.read(url)
        let plan = await QuicklinkExchange.planInBackground(incoming, existing: file.quicklinks)
        guard plan.added > 0 else {
            context.showToast(Strings.importToast(plan))
            return .keepOpen
        }
        return .push(.list(QuicklinkImportPage(feature: self, entries: incoming, plan: plan).page))
    }

    /// Adds the entries the user confirmed, decided again against the quicklinks as they are now.
    func commitImport(_ entries: [ExchangedQuicklink]) async throws -> QuicklinkImportPlan {
        let plan = await QuicklinkExchange.planInBackground(entries, existing: file.quicklinks)
        try await add(plan.quicklinks)
        return plan
    }

    private func exportToFile(context: ActionContext) async throws -> ActionOutcome {
        let request = SaveDialogRequest(
            title: Strings.exportDialogTitle, suggestedName: Strings.exportFileName, allowedTypes: ["json"])
        guard let url = await context.fileDialogs.chooseSaveLocation(request) else { return .keepOpen }
        let count = try await QuicklinkExchange.export(file.quicklinks, to: url)
        context.showToast(.success(Strings.exported(count)))
        return .keepOpen
    }
}

/// A quicklink with its parsed link, and what declarations and rows read from it. Made once per
/// change, off the main thread, never per keystroke.
nonisolated struct QuicklinkEntry: Sendable {
    let quicklink: Quicklink
    let template: LinkTemplate
    /// The link's distinct arguments, in order.
    let arguments: [TemplateArgument]
    let commandArguments: [CommandArgument]
    /// True when the link takes the text typed in root search. See ``LinkTemplate/takesQuery``.
    let takesQuery: Bool
    let requires: [Permission]
    let icon: Icon
    /// The link without `https://` and `www.`.
    let displayText: String
    /// The user's keywords and the site's name.
    let searchKeywords: [String]

    init(_ quicklink: Quicklink) {
        self.quicklink = quicklink
        let template = LinkTemplate(quicklink.link)
        self.template = template
        arguments = template.arguments
        commandArguments = template.commandArguments
        takesQuery = template.takesQuery
        requires = template.requires
        displayText = template.displayText
        icon = QuicklinkRows.icon(quicklink: quicklink, webHost: template.webHost)
        searchKeywords = quicklink.keywords + (template.webHost.map { [QuicklinkRows.siteName($0)] } ?? [])
    }

    var id: String { quicklink.id }
    var isEnabled: Bool { quicklink.isEnabled }

    /// True when root offers the quicklink when nothing else matches: fallbacks are on, it is on,
    /// it takes the typed text, and it is the default search engine or marked as a fallback.
    func offersFallback(engineID: String?, fallbacksOn: Bool) -> Bool {
        guard fallbacksOn, isEnabled, takesQuery else { return false }
        return id == engineID || quicklink.isFallback
    }
}

/// The quicklinks of one file, parsed and looked up by ID. Built off the main thread, because a
/// file can hold tens of thousands.
nonisolated struct QuicklinkIndex: Sendable {
    let file: QuicklinkFile
    let entries: [QuicklinkEntry]
    let byID: [String: QuicklinkEntry]
    /// The quicklinks that are on and take the typed text, in file order.
    let searchEngines: [QuicklinkEntry]

    init(_ file: QuicklinkFile) {
        self.file = file
        entries = file.quicklinks.map(QuicklinkEntry.init)
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchEngines = entries.filter { $0.isEnabled && $0.takesQuery }
    }

    /// The index of a file the feature changed itself.
    @concurrent static func build(_ file: QuicklinkFile) async -> QuicklinkIndex {
        QuicklinkIndex(file)
    }

    /// The index of a file as read from disk, made safe first. Nil when it holds what `current`
    /// holds, so a read of the feature's own save changes nothing.
    @concurrent static func read(_ stored: QuicklinkFile, unlessSameAs current: QuicklinkFile?) async -> QuicklinkIndex?
    {
        let prepared = stored.prepared()
        if let current, prepared == current { return nil }
        return QuicklinkIndex(prepared)
    }
}
