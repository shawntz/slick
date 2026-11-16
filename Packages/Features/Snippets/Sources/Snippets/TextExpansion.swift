import Foundation
import Kit
import KitTemplates
import Synchronization

/// Keeps keyword expansion in step with the settings and the snippets.
///
/// Every start, stop and keyword update runs off the main thread, one after another in the order
/// asked for, so the last one wins. The service calls the expansion handler off the main thread
/// too, and the handler reads ``table``, never the library.
final class ExpansionController {
    /// The settings expansion runs with.
    nonisolated struct Configuration: Hashable, Sendable {
        var isEnabled: Bool
        var prefix: String
        var options: ExpansionOptions

        init(_ settings: FeatureSettings) {
            isEnabled = settings[SnippetsSettings.expansionEnabled]
            prefix = SnippetsSettings.prefix(in: settings)
            options = ExpansionOptions(
                trigger: settings[SnippetsSettings.trigger].option,
                expandsWithinWords: settings[SnippetsSettings.expandsWithinWords],
                excludedBundleIDs: Set(settings[SnippetsSettings.excludedApps]))
        }
    }

    /// What the service last reported.
    private(set) var status: TextExpansionStatus = .stopped
    /// Called when ``status`` changes, with true when a permission went missing or came back, which
    /// the list's notice shows.
    var onStatusChange: (@MainActor (_ permissionChanged: Bool) -> Void)?
    /// The keywords being watched and what each becomes.
    let table = ExpansionTable()

    private let context: FeatureContext
    private var tail: Task<Void, Never>?
    private var applied: Configuration?

    init(context: FeatureContext) {
        self.context = context
    }

    /// True while the service watches typing, so keyword changes must reach it.
    var isWatching: Bool {
        switch status {
        case .running, .blockedBySecureInput: true
        case .stopped, .needsPermission: false
        }
    }

    /// Starts, restarts or stops expansion to match the settings, with these snippets' keywords.
    /// Never prompts: a missing permission comes back as a status.
    @discardableResult
    func apply(_ index: LibraryIndex) -> Task<Void, Never> {
        enqueue {
            let configuration = Configuration(self.context.settings)
            let status = await Self.start(
                index, configuration, table: self.table, service: self.context.textExpansion, context: self.context)
            self.applied = configuration
            self.observe(status)
        }
    }

    /// Like ``apply(_:)``, but does nothing when the settings are the ones last applied.
    @discardableResult
    func applyIfChanged(_ index: LibraryIndex) -> Task<Void, Never> {
        guard Configuration(context.settings) != applied else { return enqueue {} }
        return apply(index)
    }

    /// Hands the service these snippets' keywords without a restart, after a snippet was added,
    /// changed or deleted.
    @discardableResult
    func update(_ index: LibraryIndex) -> Task<Void, Never> {
        enqueue {
            let prefix = SnippetsSettings.prefix(in: self.context.settings)
            let service = self.isWatching ? self.context.textExpansion : nil
            await Self.register(index, prefix: prefix, table: self.table, service: service)
        }
    }

    /// Stops watching, when the feature is turned off.
    @discardableResult
    func stop() -> Task<Void, Never> {
        enqueue {
            await Self.halt(self.context.textExpansion)
            self.applied = nil
            self.observe(.stopped)
        }
    }

    /// Records a status from the service, such as secure input starting in another app.
    func observe(_ new: TextExpansionStatus) {
        guard new != status else { return }
        let permissionChanged = Self.missingPermission(in: status) != Self.missingPermission(in: new)
        status = new
        onStatusChange?(permissionChanged)
    }

    private static func missingPermission(in status: TextExpansionStatus) -> Permission? {
        if case .needsPermission(let permission) = status { return permission }
        return nil
    }

    /// What settings shows at the top of the pane, or nil when all is well.
    var featureStatus: FeatureStatus? {
        guard context.settings[SnippetsSettings.expansionEnabled] else { return nil }
        switch status {
        case .needsPermission(let permission):
            return FeatureStatus(
                .warning, Strings.expansionNeeds(permission), message: Strings.expansionNeedsMessage,
                requires: [permission])
        case .blockedBySecureInput(let owner):
            return FeatureStatus(.info, Strings.secureInput(owner), message: Strings.secureInputMessage)
        case .running, .stopped:
            return nil
        }
    }

    /// One line for a HUD after the user turned expansion on or off.
    var summary: String {
        switch status {
        case .running: Strings.expansionOn
        case .stopped: Strings.expansionOff
        case .needsPermission(let permission): Strings.expansionNeeds(permission)
        case .blockedBySecureInput(let owner): Strings.secureInput(owner)
        }
    }

    private func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    // MARK: Off the main thread

    @concurrent nonisolated static func start(
        _ index: LibraryIndex, _ configuration: Configuration, table: ExpansionTable,
        service: any TextExpansionService, context: FeatureContext
    ) async -> TextExpansionStatus {
        guard configuration.isEnabled else {
            await service.stop()
            return .stopped
        }
        let keywords = table.load(index, prefix: configuration.prefix)
        return await service.start(
            keywords: keywords, options: configuration.options, expand: handler(table: table, context: context))
    }

    @concurrent nonisolated static func halt(_ service: any TextExpansionService) async {
        await service.stop()
    }

    @concurrent nonisolated static func register(
        _ index: LibraryIndex, prefix: String, table: ExpansionTable, service: (any TextExpansionService)?
    ) async {
        let keywords = table.load(index, prefix: prefix)
        await service?.updateKeywords(keywords)
    }

    /// What the service runs when a keyword is typed. Made outside the main actor, so it never
    /// waits for it.
    nonisolated static func handler(table: ExpansionTable, context: FeatureContext)
        -> @Sendable (String) async -> ExpansionResult
    {
        { keyword in await expand(keyword, table: table, context: context) }
    }

    /// Renders the snippet for a typed keyword, fresh, so `{date}` and `{clipboard}` are current. A
    /// snippet that asks for arguments opens the panel on a form instead.
    ///
    /// Text with a line break is pasted, never typed. Typed, each break is a press of Return, which
    /// runs a line in a terminal; a paste goes through the terminal's guard for pasted text. That
    /// holds wherever the break comes from: the snippet's own text, an imported pack, `{clipboard}`
    /// or `{selection}`. Fill In Snippet pastes it after the keyword is deleted, launched as text
    /// expansion, which is the only launch that pastes at once.
    @concurrent nonisolated static func expand(_ keyword: String, table: ExpansionTable, context: FeatureContext) async
        -> ExpansionResult
    {
        guard let entry = table.entry(forKeyword: keyword) else { return .ignore }
        context.usage.recordUse(of: SnippetIDs.row(entry.id))
        let fill = ExpansionResult.runCommand(
            SnippetIDs.fillCommandID, arguments: [SnippetIDs.snippetArgument: entry.id])
        guard !entry.hasArguments else { return fill }
        let environment = TemplateEnvironment(context: context) { name in table.text(named: name) }
        let expansion = await Template(entry.text).render(in: environment).expansion
        guard !expansion.text.contains(where: \.isNewline) else { return fill }
        return .insert(expansion)
    }
}

/// The keywords being watched, as typed with the prefix, and what each one becomes. Safe to read
/// from any thread.
nonisolated final class ExpansionTable: Sendable {
    struct Entry: Hashable, Sendable {
        var id: String
        var text: String
        var hasArguments: Bool
    }

    private struct Contents {
        var entries: [String: Entry] = [:]
        var texts: [String: String] = [:]
    }

    private let contents = Mutex(Contents())

    /// Replaces the table with the expanding snippets of the index and returns their keywords. The
    /// first snippet wins when two share a keyword.
    func load(_ index: LibraryIndex, prefix: String) -> Set<String> {
        var entries: [String: Entry] = [:]
        for snippet in index.snippets where snippet.expands {
            guard let typed = snippet.typedKeyword(prefix: prefix), entries[typed] == nil else { continue }
            entries[typed] = Entry(
                id: snippet.id, text: snippet.text, hasArguments: !index.arguments(of: snippet.id).isEmpty)
        }
        let texts = index.textsByName
        contents.withLock { $0 = Contents(entries: entries, texts: texts) }
        return Set(entries.keys)
    }

    func entry(forKeyword keyword: String) -> Entry? {
        contents.withLock { $0.entries[keyword] }
    }

    func text(named name: String) -> String? {
        contents.withLock { $0.texts[name] }
    }

    var keywords: Set<String> {
        contents.withLock { Set($0.entries.keys) }
    }
}
