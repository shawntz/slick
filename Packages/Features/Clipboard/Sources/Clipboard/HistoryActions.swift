import Foundation
import Kit

/// The actions on one history item. They are built from the row's payload alone; content is read
/// from the store when an action runs, because a row never carries a whole text or an image.
struct HistoryActions {
    /// The Snippets feature's command that opens its editor with text filled in, as an undeclared
    /// `text` argument. The host hides Save as Snippet while that command is unavailable.
    static let saveAsSnippetCommand = ItemID.command(feature: "snippets", command: "create")
    static let pastePlainTextShortcut = KeyCombo(.v, [.option, .shift, .command])
    static let saveAsSnippetShortcut = KeyCombo(.s, .command)

    let store: HistoryStore
    let changes: ChangeSignal
    let context: FeatureContext

    /// Every action for a row on the history page.
    func actions(for row: Row) -> [Action] {
        guard let item = item(of: row) else { return [] }
        var actions = delivery(item)
        if [.richText, .link, .files].contains(item.kind) {
            actions.append(paste(item, plainText: true, shortcut: Self.pastePlainTextShortcut))
        }
        if item.kind == .link { actions.append(openLink(item)) }
        if item.kind == .files { actions += [openFiles(item), reveal(item)] }
        actions.append(pin(item))
        if item.kind.isTextual { actions.append(saveAsSnippet(item)) }
        actions += [delete(item), deleteAll()]
        return actions
    }

    /// The actions for the suggestion row in root search: paste, copy, and open for a link or files.
    func suggestionActions(for row: Row) -> [Action] {
        guard let item = item(of: row) else { return [] }
        var actions = delivery(item)
        if item.kind == .link { actions.append(openLink(item)) }
        if item.kind == .files { actions += [openFiles(item), reveal(item)] }
        return actions
    }

    /// Paste and Copy, in the order the user chose. The second one also answers Command-Return.
    private func delivery(_ item: RowPayload) -> [Action] {
        if context.settings[ClipboardSettings.primaryAction] == .copy {
            return [copy(item, shortcut: nil), paste(item, plainText: false, shortcut: .secondaryAction)]
        }
        return [paste(item, plainText: false, shortcut: nil), copy(item, shortcut: .secondaryAction)]
    }

    /// The payload of one of this feature's rows. A row without one, which this feature never makes,
    /// is treated as text.
    private func item(of row: Row) -> RowPayload? {
        if let payload = HistoryRows.payload(of: row) { return payload }
        return HistoryRows.key(of: row).map { RowPayload(key: $0, kind: .text, isPinned: false) }
    }

    // MARK: - Delivery

    /// Reads the item, closes the panel, then pastes through the pasteboard service.
    private func paste(_ item: RowPayload, plainText: Bool, shortcut: KeyCombo?) -> Action {
        let title =
            plainText
            ? Strings.Actions.pastePlainText
            : Strings.Actions.paste(to: context.workspace.frontmostApplication()?.name)
        let used = used
        return Action(
            title, id: plainText ? "paste-plain-text" : "paste", icon: .symbol("doc.on.clipboard"), shortcut: shortcut,
            requires: [.accessibility]
        ) { [store] context in
            guard let content = try await store.content(item.key, plainText: plainText) else {
                throw plainText ? Strings.Actions.noPlainText : Strings.Actions.missing
            }
            context.dismiss()
            do {
                try await context.pasteboard.paste(content)
            } catch PasteError.permissionMissing(let permission) {
                return .needsPermission(permission)
            } catch PasteError.targetDidNotActivate {
                throw Strings.Actions.pasteFailed
            }
            try await used(item.key, context)
            return .close()
        }
    }

    private func copy(_ item: RowPayload, shortcut: KeyCombo?) -> Action {
        let used = used
        return Action(Strings.Actions.copy, id: "copy", icon: .symbol("doc.on.doc"), shortcut: shortcut) {
            [store] context in
            guard let content = try await store.content(item.key) else { throw Strings.Actions.missing }
            await context.pasteboard.copy(content, options: [])
            try await used(item.key, context)
            return .close(hud: HUD(Strings.Actions.copied))
        }
    }

    /// Moves the item to the top after the user pasted or copied it, when the setting says so.
    private var used: @MainActor @Sendable (ItemKey, ActionContext) async throws -> Void {
        { [store, changes] key, context in
            guard context.settings[ClipboardSettings.movesUsedItemsToTop] else { return }
            if try await store.moveToTop(key, at: context.clock.now) { changes.send() }
        }
    }

    // MARK: - Opening

    private func openLink(_ item: RowPayload) -> Action {
        Action(Strings.Actions.openLink, id: "open-link", icon: .symbol("safari"), shortcut: .open) {
            [store] context in
            guard case .url(let url) = try await store.content(item.key) else { throw Strings.Actions.missing }
            context.dismiss()
            try await context.workspace.open(url)
            return .close()
        }
    }

    /// Opens the copied files in their default apps. More than a few at once asks first, as Finder
    /// does.
    private func openFiles(_ item: RowPayload) -> Action {
        Action(Strings.Actions.openFiles, id: "open-files", icon: .symbol("arrow.up.forward.app"), shortcut: .open) {
            [store] context in
            guard case .files(let urls) = try await store.content(item.key) else { throw Strings.Actions.missing }
            if urls.count > Self.filesOpenedWithoutAsking {
                guard await context.confirm(Strings.Actions.openManyConfirmation(urls.count)) else { return .keepOpen }
            }
            context.dismiss()
            for url in urls { try await context.workspace.open(url) }
            return .close()
        }
    }

    /// How many files Open opens before it asks.
    static let filesOpenedWithoutAsking = 10

    private func reveal(_ item: RowPayload) -> Action {
        Action(Strings.Actions.reveal, id: "reveal", icon: .symbol("folder"), shortcut: .reveal) { [store] context in
            guard case .files(let urls) = try await store.content(item.key) else { throw Strings.Actions.missing }
            await context.workspace.reveal(urls)
            return .close()
        }
    }

    // MARK: - Keeping

    private func pin(_ item: RowPayload) -> Action {
        let pinning = !item.isPinned
        return Action(
            pinning ? Strings.Actions.pin : Strings.Actions.unpin, id: "pin",
            icon: .symbol(pinning ? "pin" : "pin.slash"), shortcut: .pin
        ) { [store, changes] context in
            guard try await store.setPinned(pinning, key: item.key) else { throw Strings.Actions.missing }
            changes.send()
            context.showToast(.success(pinning ? Strings.Actions.pinned : Strings.Actions.unpinned))
            return .keepOpen
        }
    }

    /// Hands the text to the Snippets feature's editor.
    private func saveAsSnippet(_ item: RowPayload) -> Action {
        let command = Self.saveAsSnippetCommand
        return Action(
            Strings.Actions.saveAsSnippet, id: "save-as-snippet", icon: .symbol("text.badge.plus"),
            shortcut: Self.saveAsSnippetShortcut, requiresCommand: command
        ) { [store] _ in
            guard case .text(let text) = try await store.content(item.key, plainText: true) else {
                throw Strings.Actions.missing
            }
            return .run(command, arguments: ["text": text])
        }
    }

    // MARK: - Deleting

    private func delete(_ item: RowPayload) -> Action {
        Action(
            Strings.Actions.delete, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            section: Strings.Actions.deleteSection, confirmation: Strings.Actions.deleteConfirmation
        ) { [store, changes] context in
            try await store.delete(item.key)
            changes.send()
            context.showToast(.success(Strings.Actions.deleted))
            return .keepOpen
        }
    }

    private func deleteAll() -> Action {
        Action(
            Strings.Actions.deleteAll, id: "delete-all", icon: .symbol("trash.slash"), shortcut: .removeAll,
            style: .destructive, section: Strings.Actions.deleteSection,
            confirmation: Strings.Actions.deleteAllConfirmation
        ) { [store, changes] context in
            let removed = try await store.deleteAll(keepingPinned: true)
            changes.send()
            context.showToast(.success(Strings.Actions.deleted(removed)))
            return .keepOpen
        }
    }
}
