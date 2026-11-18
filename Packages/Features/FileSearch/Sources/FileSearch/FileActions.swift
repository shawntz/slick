import Foundation
import Kit

/// The actions of a file or folder row, wherever it shows: root search, the Search Files page, or
/// a row root search rebuilt from a snapshot after a relaunch. Everything comes from the row's ID
/// and payload, so building them reads nothing.
///
/// In the action panel they come in three groups. First the ones that open or look: Open with
/// Return, Show in Finder with Command-Return, as in the Apps feature, Open With, Quick Look, Get
/// Info, Open in Terminal for a folder, and Share. Then Copy, then Manage, which changes the disk.
/// Shortcuts follow Finder where it has one and Kit's constants otherwise; an action Finder gives
/// no key gets none.
///
/// Every change to the disk goes through the feature's ``FileOperations`` service. After a change
/// the index applies it before the page loads again, so the list shows the result at once. Uses
/// on the Search Files page are recorded for its recents; root search records its own.
@MainActor final class FileActions {
    /// Finder's shortcuts that Kit has no constant for.
    enum Shortcut {
        static let getInfo = KeyCombo(.i, .command)
    }

    /// The app Open in Terminal hands a folder to.
    static let terminalBundleID = "com.apple.Terminal"
    /// The rename form's one field.
    static let nameField = "name"

    private let controller: IndexController
    private let operations: any FileOperations
    private let details: FileDetails

    init(controller: IndexController, operations: any FileOperations, details: FileDetails) {
        self.controller = controller
        self.operations = operations
        self.details = details
    }

    /// One row's item, as the actions use it.
    struct File: Sendable {
        var url: URL
        var path: String
        var name: String
        var item: FileItem

        init(row: Row) {
            url = FileRows.url(of: row)
            path = row.id.key
            name = Paths.name(of: path)
            item = FileRows.item(of: row)
        }

        /// A folder the user can open in Terminal, not a package such as an app.
        var isPlainFolder: Bool { item.isFolder && !item.isPackage }
    }

    func actions(for row: Row) -> [Action] {
        let file = File(row: row)
        var actions = [
            Action.open(file.url).recordingUse(),
            Action.reveal([file.url]).with(shortcut: .secondaryAction).recordingUse(),
            Action.openWith(file.url).recordingUse(),
            Action.quickLook(file.url),
            getInfo(row, file),
        ]
        if file.isPlainFolder { actions.append(openInTerminal(file).recordingUse()) }
        actions.append(.share([.file(file.url)]))
        actions += copyActions(file).map { $0.with(section: Strings.Actions.copySection) }
        actions += [rename(file), duplicate(file), compress(file), moveTo(file), copyTo(file), trash(file)].map {
            $0.with(section: Strings.Actions.manageSection)
        }
        return actions
    }

    // MARK: - Looking

    /// Pushes a page with the item's kind, size, dates and folder, and its preview or icon.
    private func getInfo(_ row: Row, _ file: File) -> Action {
        let details = details
        let lookActions = [
            Action.open(file.url), .reveal([file.url]).with(shortcut: .secondaryAction), .openWith(file.url),
            .quickLook(file.url),
        ]
        let pageActions = lookActions + copyActions(file)
        return Action(
            Strings.Actions.getInfo, id: "get-info", icon: .symbol("info.circle"), shortcut: Shortcut.getInfo
        ) { context in
            let source = FileInfoSource(row: row, details: details, locale: context.clock.locale, actions: pageActions)
            return .push(.detail(DetailPage(title: DisplayText.fileName(file.name), source: source)))
        }
    }

    private func openInTerminal(_ file: File) -> Action {
        Action(Strings.Actions.openInTerminal, id: "open-in-terminal", icon: .symbol("terminal")) { context in
            context.dismiss()
            try await context.workspace.open([file.url], withApplication: Self.terminalBundleID)
            return .close()
        }
    }

    private func copyActions(_ file: File) -> [Action] {
        let copyFile = Action.copy(
            .files([file.url]), title: Strings.Actions.copyFile, hud: Strings.Actions.copiedFile, shortcut: .copy)
        let copyName = Action.copy(file.name, title: Strings.Actions.copyName, hud: Strings.Actions.copiedName)
        return [
            copyFile.with(id: "copy-file").recordingUse(), Action.copyPath(file.url).recordingUse(),
            copyName.with(id: "copy-name"),
        ]
    }

    // MARK: - Changing

    private func rename(_ file: File) -> Action {
        Action(Strings.Actions.rename, id: "rename", icon: .symbol("pencil"), shortcut: .edit) { [self] _ in
            .push(.form(renameForm(file)))
        }
    }

    /// One field with the current name. The validator says why a name cannot be used, including one
    /// another item already has; renaming refuses to replace an item even if one appears meanwhile.
    private func renameForm(_ file: File) -> FormPage {
        let operations = operations
        let field = Self.nameField
        return FormPage(
            title: Strings.Operations.renameTitle(file.name),
            fields: [.text(field, title: Strings.Operations.nameField, initial: file.name, isRequired: true)],
            submitTitle: Strings.Operations.renameButton,
            validate: { values in
                let name = FileNames.cleaned(values.text(field))
                if let problem = FileNames.problem(with: name) {
                    return [field: FieldError(Strings.Operations.problem(problem))]
                }
                if name != file.name, await operations.isTaken(name, besides: file.url) {
                    return [field: FieldError(Strings.Operations.nameTaken(name))]
                }
                return [:]
            },
            submit: { [self] values, context in
                let name = FileNames.cleaned(values.text(field))
                guard name != file.name else { return .pop }
                let renamed = try await change(.rename, file, context: context) {
                    try await $0.rename(file.url, to: name)
                }
                context.showToast(.success(Strings.Operations.renamed(to: renamed.lastPathComponent)))
                return .pop
            })
    }

    private func duplicate(_ file: File) -> Action {
        Action(
            Strings.Actions.duplicate, id: "duplicate", icon: .symbol("plus.square.on.square"), shortcut: .duplicate,
            runPolicy: .concurrent
        ) { [self] context in
            let copy = try await withProgress(Strings.Operations.duplicating(file.name), context: context) {
                try await self.change(.duplicate, file, context: context) { try await $0.duplicate(file.url) }
            }
            copy.toast.update(
                .success(
                    Strings.Operations.duplicated(file.name),
                    message: Strings.Operations.copyNamed(copy.url.lastPathComponent)))
            return .keepOpen
        }
    }

    private func compress(_ file: File) -> Action {
        Action(Strings.Actions.compress, id: "compress", icon: .symbol("doc.zipper"), runPolicy: .concurrent) {
            [self] context in
            let archive = try await withProgress(Strings.Operations.compressing(file.name), context: context) {
                try await self.change(.compress, file, context: context) { try await $0.compress(file.url) }
            }
            archive.toast.update(
                .success(
                    Strings.Operations.compressed(file.name),
                    message: Strings.Operations.archiveNamed(archive.url.lastPathComponent)))
            return .keepOpen
        }
    }

    private func moveTo(_ file: File) -> Action {
        Action(Strings.Actions.moveTo, id: "move-to", icon: .symbol("arrow.turn.down.right"), runPolicy: .concurrent) {
            [self] context in
            guard let folder = await chooseFolder(Strings.Operations.moveToPrompt(file.name), context: context) else {
                return .keepOpen
            }
            let folderName = folder.lastPathComponent
            let moved = try await withProgress(Strings.Operations.moving(file.name), context: context) {
                try await self.change(.move, file, folder: folderName, context: context) {
                    try await $0.move(file.url, into: folder)
                }
            }
            moved.toast.update(.success(Strings.Operations.moved(to: folderName)))
            return .keepOpen
        }
    }

    private func copyTo(_ file: File) -> Action {
        Action(Strings.Actions.copyTo, id: "copy-to", icon: .symbol("folder.badge.plus"), runPolicy: .concurrent) {
            [self] context in
            guard let folder = await chooseFolder(Strings.Operations.copyToPrompt(file.name), context: context) else {
                return .keepOpen
            }
            let folderName = folder.lastPathComponent
            let copied = try await withProgress(Strings.Operations.copying(file.name), context: context) {
                try await self.change(.copy, file, folder: folderName, context: context) {
                    try await $0.copy(file.url, into: folder)
                }
            }
            // Into its own folder the copy took a new name, which the toast gives.
            let name = copied.url.lastPathComponent
            copied.toast.update(
                .success(
                    Strings.Operations.copied(to: folderName),
                    message: name == file.name ? nil : Strings.Operations.copyNamed(name)))
            return .keepOpen
        }
    }

    /// Asks first, naming the item as its row does, on one line and in stored order.
    private func trash(_ file: File) -> Action {
        let question = Confirmation(
            Strings.Actions.trashQuestion(FileRows.title(for: file.name)), confirmTitle: Strings.Actions.trashConfirm,
            isDestructive: true)
        return Action(
            Strings.Actions.moveToTrash, id: "move-to-trash", icon: .symbol("trash"), shortcut: .remove,
            style: .destructive, confirmation: question
        ) { [self] context in
            _ = try await change(.trash, file, context: context) { try await $0.trash(file.url) }
            context.showToast(.success(Strings.Actions.movedToTrash))
            return .keepOpen
        }
    }

    // MARK: - Running a change

    /// Runs one change through the operations service. Then the index applies what changed and the
    /// page loads again, so the list shows the result at once. An item that went away or moved is
    /// forgotten by root search. A failure becomes a title and a sentence.
    ///
    /// An item inside a protected place the feature does not search now, such as a remembered row
    /// from a folder the user stopped searching, is left alone, so no change can raise a prompt.
    private func change(
        _ kind: FileOperationKind, _ file: File, folder: String? = nil, context: ActionContext,
        _ work: @escaping @Sendable (any FileOperations) async throws -> URL
    ) async throws -> URL {
        let failure = Strings.Operations.failure(kind)
        if let plan = controller.plan, plan.blocked.contains(where: { Paths.isInside(file.path, $0) }) {
            throw ActionFailure(failure, message: Strings.Operations.notSearched(file.name))
        }
        let result: URL
        do {
            result = try await work(operations)
        } catch let error as FileOperationError {
            throw ActionFailure(
                failure, message: Strings.Operations.explain(error, kind: kind, item: file.name, folder: folder))
        }
        await controller.applyNow([file.url, result])
        if kind.removesOriginal { context.usage.forget(FileRows.id(for: file.path)) }
        context.reload()
        return result
    }

    /// Shows a progress toast while `work` runs, and takes it away when `work` throws, so the
    /// host's failure toast stands alone.
    private func withProgress(
        _ title: String, context: ActionContext, _ work: () async throws -> URL
    ) async throws -> (url: URL, toast: ToastHandle) {
        let toast = context.showToast(.progress(title))
        do {
            return (try await work(), toast)
        } catch {
            toast.dismiss()
            throw error
        }
    }

    /// The folder the user picks in an open dialog that offers folders only, or nil when they
    /// cancel. A file that comes back anyway still fails with a sentence.
    private func chooseFolder(_ prompt: String, context: ActionContext) async -> URL? {
        let request = OpenDialogRequest(title: prompt, canChooseDirectories: true, canChooseFiles: false)
        return await context.fileDialogs.chooseFiles(request).first
    }
}

/// The kinds of change the file actions make.
nonisolated enum FileOperationKind: Sendable {
    case rename
    case duplicate
    case compress
    case move
    case copy
    case trash

    /// The item is gone from where it was, so root search forgets it there.
    var removesOriginal: Bool {
        switch self {
        case .rename, .move, .trash: true
        case .duplicate, .compress, .copy: false
        }
    }
}

extension IndexController {
    /// Queues these paths as one batch and waits until it was applied. While a walk holds the index
    /// queue, such as the first build or the catch-up walk after a launch, it does not wait: the
    /// batch follows the walk, and the walk's end loads the page again.
    func applyNow(_ urls: [URL]) async {
        submit(urls)
        guard !summary.isWalking else { return }
        await waitUntilIdle()
    }
}
