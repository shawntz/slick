import Foundation
import Kit

/// Notes: quick notes kept as plain Markdown files that any editor can open.
///
/// - A note is one Markdown file in the notes folder, by default `Notes` in the feature's data
///   folder. Its title is its first line, or that line's heading text, and the file is named after
///   it. Tags are a line of `#tags` at the end of the note; pins live in the feature's own data
///   folder, so a note stays plain Markdown.
/// - Search Notes lists every note, pinned first, then by the day it changed, and searches titles
///   and text off the main thread.
/// - `note` and some text in root search saves a note on Return. Append to Note adds text to the end
///   of a note. Note titles can join root search behind a setting that starts off.
/// - The folder is watched, so an edit in another app shows at once. Every read and write runs in
///   ``NoteStore``, an actor, and every write is atomic.
/// - A setting points the feature at a folder the user picks. A folder macOS guards is read for
///   the first time right after the choice, which is when macOS asks.
public final class NotesFeature: Feature {
    public static let manifest = FeatureManifest(
        id: NoteIDs.feature, name: Strings.featureName, icon: .symbol("note.text"), summary: Strings.featureSummary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.accessibilityReason)])

    let context: FeatureContext
    let library: NoteLibrary
    private(set) lazy var actions = NoteActions(feature: self)
    private(set) lazy var forms = NoteForms(feature: self)
    private lazy var list = NoteList(feature: self)
    private lazy var catalog = NoteCatalog(feature: self)
    private lazy var capture = QuickCapture(feature: self)
    private var listening: [Task<Void, Never>] = []

    /// Does no I/O: the library holds paths until ``activate()``.
    public convenience init(context: FeatureContext) {
        self.init(context: context, limits: .standard)
    }

    /// For tests that lower the caps.
    init(context: FeatureContext, limits: NoteLimits) {
        self.context = context
        library = NoteLibrary(context: context, disk: context.service(NoteDiskKey.self), limits: limits)
    }

    /// Follows the folder setting, then reads the folder and starts watching it in a task, so it
    /// returns at once. Reading the feature's own folder asks for nothing; a guarded folder is read
    /// here only when it was read before, right after the user chose it.
    public func activate() async {
        for task in listening { task.cancel() }
        let folderChanges = context.settings.changes(of: NotesSettings.folder)
        let library = library
        listening = [
            Task {
                for await _ in folderChanges { await library.followFolderSetting(userAsked: false) }
            }
        ]
        library.start()
    }

    public func deactivate() async {
        for task in listening { task.cancel() }
        listening = []
        await library.stop()
    }

    public func waitUntilReady() async {
        await library.ready()
    }

    // MARK: Declarations

    public var commands: [Command] {
        [
            Command(
                id: NoteIDs.searchCommand, title: Strings.searchCommand, icon: Self.manifest.icon,
                keywords: Strings.searchKeywords
            ) { [unowned self] _ in
                .push(.list(searchPage()))
            },
            // Other code may hand text to it as an undeclared argument.
            Command(
                id: NoteIDs.createCommand, title: Strings.createCommand, icon: .symbol("square.and.pencil"),
                keywords: Strings.createKeywords
            ) { [unowned self] context in
                .push(.form(forms.create(body: context.arguments[NoteIDs.textArgument] ?? "")))
            },
            // Nothing is added until the user picks a note, so a link that names it is safe.
            Command(
                id: NoteIDs.appendCommand, title: Strings.appendCommand, icon: .symbol("text.append"),
                keywords: Strings.appendKeywords,
                arguments: [
                    CommandArgument(NoteIDs.textArgument, placeholder: Strings.textPlaceholder, isOptional: true)
                ]
            ) { [unowned self] context in
                .push(.list(pickerPage(text: context.arguments[NoteIDs.textArgument] ?? "")))
            },
        ]
    }

    public var declarationChanges: ChangeSignal? { library.statusChanges }

    public var catalogSources: [any CatalogSource] { [catalog] }

    public var liveProviders: [LiveProvider] { [.instant(capture)] }

    public var status: FeatureStatus? {
        let index = library.index
        if let problem = index.problem {
            return FeatureStatus(
                problem == .waitingForRead ? .info : .failure, Strings.problemTitle(problem),
                message: Strings.problemMessage(problem, folder: index.folder))
        }
        switch library.pinState {
        case .unreadable:
            return FeatureStatus(.warning, Strings.pinsUnreadableTitle, message: Strings.pinsUnreadableMessage)
        case .newerVersion:
            return FeatureStatus(.warning, Strings.pinsNewerTitle, message: Strings.pinsNewerMessage)
        case .loading, .ready:
            return nil
        }
    }

    public var settingsPane: SettingsPane? {
        let folder = library.index.folder
        return SettingsPane([
            SettingsSection(
                Strings.rootSection,
                items: [
                    .toggle(Strings.rootToggle, key: NotesSettings.showsInRootSearch, info: Strings.rootToggleInfo)
                ]),
            SettingsSection(
                Strings.folderSection, footer: Strings.folderFooter,
                items: [
                    .note(folder.isDefault ? Strings.defaultFolderNote : Strings.folderNote(folder.path)),
                    .button(Strings.chooseFolder) { [unowned self] context in await chooseFolder(context) },
                    .button(Strings.useDefaultFolder) { [unowned self] context in await useDefaultFolder(context) },
                    .button(Strings.showInFinder) { [unowned self] context in
                        await context.workspace.reveal([library.index.folder.url])
                    },
                ]),
            SettingsSection(
                Strings.captureSection,
                items: [.toggle(Strings.captureToggle, key: NotesSettings.quickCapture, info: Strings.captureNote)]),
        ])
    }

    // MARK: Pages

    func searchPage() -> ListPage {
        ListPage(
            list, searchPlaceholder: Strings.searchPlaceholder, showsDetail: true,
            emptyState: EmptyState(icon: Self.manifest.icon, title: Strings.emptyTitle, message: Strings.emptyMessage))
    }

    func pickerPage(text: String) -> ListPage {
        ListPage(
            NotePicker(feature: self, text: text), title: Strings.appendCommand,
            searchPlaceholder: Strings.pickerPlaceholder,
            emptyState: EmptyState(
                icon: .symbol("text.append"), title: Strings.pickerEmptyTitle, message: Strings.pickerEmptyMessage))
    }

    /// A note on a page of its own.
    func notePage(_ fileName: String) -> Page {
        let title = library.index.note(named: fileName)?.title ?? Strings.untitledNote
        return .detail(DetailPage(title: title, source: NoteDetailSource(feature: self, fileName: fileName)))
    }

    // MARK: The folder

    /// The banner over a list of notes: why the folder could not be read with the way back to the
    /// default folder, or which caps the folder passes.
    func notice(for index: NoteIndex) -> Notice? {
        if let problem = index.problem {
            return Notice(
                icon: .symbol("exclamationmark.triangle", tint: .orange), title: Strings.problemTitle(problem),
                message: Strings.problemMessage(problem, folder: index.folder),
                action: problemActions(for: index).notice)
        }
        guard !index.stats.isQuiet else { return nil }
        return Notice(
            icon: .symbol("info.circle"), title: Strings.limitedTitle,
            message: Strings.limitsMessage(index.stats, limits: library.limits, locale: context.clock.locale))
    }

    /// The buttons for a folder problem: on the notice, the way out; in the empty state, the way to
    /// try again. A folder that waits for its first read offers that read first.
    func problemActions(for index: NoteIndex) -> (notice: Action?, emptyState: [Action]) {
        if index.problem == .waitingForRead {
            return (readFolderAction(), index.folder.isDefault ? [] : [useDefaultFolderAction()])
        }
        if index.folder.isDefault { return (readFolderAction(), []) }
        return (useDefaultFolderAction(), [readFolderAction()])
    }

    /// Reads the folder now. For a guarded folder this is the read macOS may ask about.
    func readFolderAction() -> Action {
        let library = library
        return Action(Strings.readFolder, id: "read-folder", icon: .symbol("arrow.clockwise")) { _ in
            await library.followFolderSetting(userAsked: true)
            return .keepOpen
        }
    }

    /// Goes back to the folder in the feature's own data folder.
    func useDefaultFolderAction() -> Action {
        Action(Strings.useDefaultFolder, id: "use-default-folder", icon: .symbol("folder")) { [unowned self] context in
            await useDefaultFolder(context)
            return .keepOpen
        }
    }

    /// Lets the user pick a folder, then reads it at once, so macOS asks now, when the user just
    /// chose it, if it asks at all. Notes in the old folder stay there.
    func chooseFolder(_ context: ActionContext) async {
        let request = OpenDialogRequest(
            title: Strings.chooseFolderDialog, canChooseDirectories: true, canChooseFiles: false)
        guard let chosen = await context.fileDialogs.chooseFiles(request).first, chosen.isFileURL else { return }
        let path = PosixNoteDisk.comparablePath(chosen)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return }
        if path == PosixNoteDisk.comparablePath(NoteLibrary.defaultFolderURL(for: self.context)) {
            self.context.settings.reset(NotesSettings.folder)
        } else {
            self.context.settings[NotesSettings.folder] = path
        }
        await library.followFolderSetting(userAsked: true)
        let index = library.index
        if let problem = index.problem {
            context.showToast(
                .failure(Strings.problemTitle(problem), message: Strings.problemMessage(problem, folder: index.folder)))
        } else {
            context.showToast(.success(Strings.folderChanged, message: Strings.folderChangedMessage))
        }
    }

    func useDefaultFolder(_ context: ActionContext) async {
        self.context.settings.reset(NotesSettings.folder)
        await library.followFolderSetting(userAsked: false)
        context.showToast(.success(Strings.usingDefaultFolder))
    }
}
