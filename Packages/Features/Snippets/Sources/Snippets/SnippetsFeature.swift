import Foundation
import Kit
import KitStorage
import KitTemplates

/// Snippets: saved text with placeholders, pasted from a list or from root search, or inserted by
/// typing its keyword in any app.
///
/// Snippets live in one JSON file in the feature's data folder. Keyword expansion watches typing,
/// so it stays off until the user turns it on, and it never asks for a permission by itself.
public final class SnippetsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: SnippetIDs.feature, name: Strings.featureName, icon: .symbol("text.quote"),
        summary: Strings.featureSummary,
        permissions: [
            PermissionNeed(.accessibility, reason: Strings.accessibilityReason),
            PermissionNeed(.inputMonitoring, reason: Strings.inputMonitoringReason),
        ])

    let context: FeatureContext
    let library: SnippetLibrary
    let expansion: ExpansionController
    private(set) lazy var actions = SnippetActions(feature: self)
    private lazy var source = SnippetSource(feature: self)
    /// Sent when ``status`` changes, which is the only declaration that changes.
    private let statusChanges = ChangeSignal()
    private var activation: Task<Void, Never>?
    private var listening: [Task<Void, Never>] = []
    /// Follows the permission expansion is waiting for, and only while it waits.
    private var grantWatch: Task<Void, Never>?
    private var isActive = false

    /// Does no I/O: the library only holds the file's path.
    public init(context: FeatureContext) {
        self.context = context
        library = SnippetLibrary(context: context)
        expansion = ExpansionController(context: context)
        let expansion = expansion
        let statusChanges = statusChanges
        // A keyword change reaches the service off the main thread, without a restart.
        library.onChange = { index in await expansion.update(index).value }
        library.onStateChange = { statusChanges.send() }
        // The list's notice follows a missing permission, so the open list reloads when one goes
        // missing or comes back. Secure input changes only the status in settings.
        let libraryChanges = library.changes
        expansion.onStatusChange = { [weak self] permissionChanged in
            statusChanges.send()
            guard permissionChanged else { return }
            libraryChanges.send()
            self?.followMissingPermission()
        }
    }

    /// Starts listening, then loads the snippets and starts expansion in a task, so it returns at
    /// once. Pages and root search wait for the load on their own.
    public func activate() async {
        isActive = true
        // Subscribe before anything starts, so no change in between is lost.
        let statuses = context.textExpansion.statusChanges()
        let settingChanges = context.settings.changes(ofAny: SnippetsSettings.expansionKeys)
        let expansion = expansion
        listening = [
            Task { for await status in statuses { expansion.observe(status) } },
            Task { [weak self] in
                for await _ in settingChanges {
                    guard let self else { return }
                    await expansion.applyIfChanged(self.library.index).value
                }
            },
        ]
        let library = library
        let watcher = context.fileWatcher
        activation = Task { [weak self] in
            await library.refresh()
            guard !Task.isCancelled, let self else { return }
            self.listening.append(library.watch(with: watcher))
            await expansion.apply(library.index).value
        }
    }

    public func deactivate() async {
        isActive = false
        activation?.cancel()
        await activation?.value
        for task in listening { task.cancel() }
        listening = []
        grantWatch?.cancel()
        grantWatch = nil
        await expansion.stop().value
    }

    /// True while expansion waits for a permission and the feature follows it.
    var isWatchingPermission: Bool { grantWatch != nil }

    /// While expansion waits for a permission, follows it, so a grant in System Settings starts
    /// expansion without a relaunch. The live permission stream checks once a second, so it is open
    /// only while expansion is on and waiting, never while the feature idles.
    private func followMissingPermission() {
        grantWatch?.cancel()
        grantWatch = nil
        guard isActive, context.settings[SnippetsSettings.expansionEnabled],
            case .needsPermission(let permission) = expansion.status
        else { return }
        let grants = context.permissions.changes(of: permission)
        grantWatch = Task { [weak self] in
            for await status in grants where status.isGranted {
                guard let self else { return }
                // Starting again ends this watch through the status change, or keeps it when
                // expansion still waits for the same permission.
                await self.expansion.apply(self.library.index).value
            }
        }
    }

    /// Waits until ``activate()`` has loaded the snippets and started expansion.
    func ready() async {
        await activation?.value
    }

    // MARK: Declarations

    public var commands: [Command] {
        let forms = SnippetForms(feature: self)
        return [
            Command(
                id: SnippetIDs.searchCommand, title: Strings.searchCommand, icon: Self.manifest.icon,
                keywords: Strings.searchKeywords
            ) { _ in
                await self.library.ready()
                return .push(.list(self.searchPage()))
            },
            // Other features hand text to it as undeclared arguments, as clipboard history's "Save as
            // Snippet" may.
            Command(id: SnippetIDs.createCommand, title: Strings.createCommand, icon: .symbol("plus")) { context in
                let text = context.arguments[SnippetIDs.textArgument] ?? ""
                var name = context.arguments[SnippetIDs.nameArgument] ?? ""
                if name.isEmpty, !text.isEmpty {
                    await self.library.ready()
                    name = SnippetForms.suggestedName(for: text, in: self.library.index)
                }
                return .push(.form(forms.editor(SnippetDraft(name: name, text: text))))
            },
            Command(id: SnippetIDs.editCommand, title: Strings.editCommand, icon: .symbol("pencil"), showsInRoot: false)
            { context in
                let snippet = try await self.snippet(named: context.arguments)
                return .push(.form(forms.editor(SnippetDraft(snippet), editing: snippet.id)))
            },
            // A keyword typed in another app opens this when its snippet asks for arguments. Only a
            // typed keyword pastes without asking. Any other launch, such as a link from a web page,
            // shows the form, so nothing is pasted until the user presses Paste Snippet.
            Command(
                id: SnippetIDs.fillCommand, title: Strings.fillCommand, icon: Self.manifest.icon,
                requires: [.accessibility], showsInRoot: false
            ) { context in
                let snippet = try await self.snippet(named: context.arguments)
                guard self.library.index.arguments(of: snippet.id).isEmpty, context.launch == .textExpansion else {
                    return .push(.form(forms.arguments(for: snippet, delivery: .paste)))
                }
                try await context.pasteboard.paste(try await self.render(id: snippet.id).expansion)
                return .close()
            },
            Command(
                id: SnippetIDs.importCommand, title: Strings.importCommand, icon: .symbol("square.and.arrow.down")
            ) { context in
                try await self.importSnippets(context)
                return .keepOpen
            },
            Command(id: SnippetIDs.exportCommand, title: Strings.exportCommand, icon: .symbol("square.and.arrow.up")) {
                context in
                try await self.exportSnippets(context)
            },
            Command(
                id: SnippetIDs.turnOnCommand, title: Strings.turnOnCommand, icon: .symbol("keyboard"),
                keywords: Strings.expansionKeywords, requires: [.inputMonitoring, .accessibility]
            ) { _ in
                await self.setExpansion(true)
            },
            Command(
                id: SnippetIDs.turnOffCommand, title: Strings.turnOffCommand, icon: .symbol("keyboard"),
                keywords: Strings.expansionKeywords
            ) { _ in
                await self.setExpansion(false)
            },
        ]
    }

    public var declarationChanges: ChangeSignal? { statusChanges }

    public var catalogSources: [any CatalogSource] { [source] }

    /// The same object answers a typed keyword at the top of root search, under the catalog's IDs.
    public var liveProviders: [LiveProvider] { [.instant(source)] }

    /// A file that cannot be read comes first; then what expansion needs.
    public var status: FeatureStatus? {
        switch library.state {
        case .unreadable:
            return FeatureStatus(
                .failure, Strings.unreadableTitle, message: Strings.unreadableMessage(SnippetLibrary.fileName))
        case .newerVersion:
            return FeatureStatus(.warning, Strings.newerFileTitle, message: Strings.newerFileMessage)
        case .loading, .ready:
            return expansion.featureStatus
        }
    }

    public var universalActions: [UniversalActionProvider] {
        let forms = SnippetForms(feature: self)
        let library = library
        return [
            .text { text in
                [
                    Action(Strings.saveAsSnippet, id: "save-as-snippet", icon: .symbol("text.badge.plus")) { _ in
                        await library.ready()
                        let draft = SnippetDraft(
                            name: SnippetForms.suggestedName(for: text, in: library.index), text: text)
                        return .push(.form(forms.editor(draft)))
                    }
                ]
            }
        ]
    }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.expansionSection,
                items: [
                    .toggle(
                        Strings.expandToggle, key: SnippetsSettings.expansionEnabled, info: Strings.expandToggleInfo),
                    .picker(Strings.triggerPicker, key: SnippetsSettings.trigger) { $0.title },
                    .textField(
                        Strings.prefixField, key: SnippetsSettings.keywordPrefix,
                        placeholder: Strings.prefixPlaceholder,
                        info: Strings.prefixInfo),
                    .toggle(
                        Strings.withinWordsToggle, key: SnippetsSettings.expandsWithinWords,
                        info: Strings.withinWordsInfo),
                    .list(
                        Strings.excludedAppsList, key: SnippetsSettings.excludedApps, itemKind: .application,
                        info: Strings.excludedAppsInfo),
                    .permission(.inputMonitoring, info: Strings.inputMonitoringInfo),
                    .permission(.accessibility, info: Strings.accessibilityInfo),
                ]),
            SettingsSection(
                Strings.searchSection,
                items: [
                    .toggle(Strings.rootToggle, key: SnippetsSettings.showsInRootSearch, info: Strings.rootToggleInfo),
                    .picker(Strings.orderPicker, key: SnippetsSettings.order) { $0.title },
                ]),
            SettingsSection(
                Strings.filesSection, footer: Strings.showFileInfo,
                items: [
                    .button(Strings.importCommand) { context in try await self.importSnippets(context) },
                    .button(Strings.exportCommand) { context in _ = try await self.exportSnippets(context) },
                    .button(Strings.showFileAction) { context in
                        await context.workspace.reveal([self.library.fileURL])
                    },
                ]),
        ])
    }

    // MARK: Pages and helpers

    func searchPage() -> ListPage {
        ListPage(
            source, searchPlaceholder: Strings.searchPlaceholder, filter: SnippetRows.filter(library.index),
            showsDetail: true,
            emptyState: EmptyState(
                icon: Self.manifest.icon, title: Strings.emptyTitle, message: Strings.emptyMessage,
                actions: [
                    .runCommand(
                        SnippetIDs.command(SnippetIDs.createCommand), title: Strings.createAction, icon: .symbol("plus")
                    ),
                    .runCommand(
                        SnippetIDs.command(SnippetIDs.importCommand), title: Strings.importCommand,
                        icon: .symbol("square.and.arrow.down")),
                ]))
    }

    /// The snippet's text with its placeholders filled in, rendered off the main thread.
    func render(id: String, arguments: [String: String] = [:]) async throws -> RenderedTemplate {
        guard let snippet = library.index.snippet(id: id) else { throw ActionFailure(Strings.snippetGone) }
        return await SnippetRenderer.render(
            snippet.text, arguments: arguments, texts: library.index.textsByName, context: context)
    }

    /// The snippet a hidden command was handed by ID.
    private func snippet(named arguments: CommandArguments) async throws -> Snippet {
        await library.ready()
        guard let snippet = arguments[SnippetIDs.snippetArgument].flatMap(library.index.snippet(id:)) else {
            throw ActionFailure(Strings.snippetGone)
        }
        return snippet
    }

    private func setExpansion(_ isEnabled: Bool) async -> ActionOutcome {
        context.settings[SnippetsSettings.expansionEnabled] = isEnabled
        await library.ready()
        await expansion.apply(library.index).value
        return .close(hud: HUD(expansion.summary))
    }

    // MARK: Import and export

    /// Asks for files, then adds their snippets. Nothing the user has is changed.
    func importSnippets(_ context: ActionContext) async throws {
        let request = OpenDialogRequest(title: Strings.importDialog, allowedTypes: ["json"], allowsMultiple: true)
        let files = await context.fileDialogs.chooseFiles(request)
        guard !files.isEmpty else { return }
        var entries: [TransferEntry] = []
        for file in files {
            do {
                entries += try await SnippetImport.read(file)
            } catch {
                context.showToast(
                    .failure(Strings.importFailed(file.lastPathComponent), message: Strings.importFailedMessage))
                return
            }
        }
        await library.ready()
        let settings = self.context.settings
        let rules = SnippetValidation.Rules(
            prefix: SnippetsSettings.prefix(in: settings), trigger: settings[SnippetsSettings.trigger])
        let summary = try await library.importEntries(entries, rules: rules)
        let notes = Strings.importNotes(
            duplicates: summary.duplicates, keywordClashes: summary.keywordClashes, incomplete: summary.incomplete,
            renamed: summary.renamed, keywordsLeftOut: summary.keywordsLeftOut)
        context.showToast(.success(Strings.imported(summary.added), message: notes))
    }

    /// Asks where to save, then writes every snippet.
    func exportSnippets(_ context: ActionContext) async throws -> ActionOutcome {
        await library.ready()
        let entries = library.index.snippets.map(TransferEntry.init)
        guard !entries.isEmpty else {
            context.showToast(Toast(.info, Strings.nothingToExport))
            return .keepOpen
        }
        let request = SaveDialogRequest(
            title: Strings.exportDialog, suggestedName: Strings.exportFileName, allowedTypes: ["json"])
        guard let file = await context.fileDialogs.chooseSaveLocation(request) else { return .keepOpen }
        try await JSONFileStore<[TransferEntry]>(url: file).save(entries)
        return .close(hud: HUD(Strings.exported(entries.count), style: .success))
    }
}
