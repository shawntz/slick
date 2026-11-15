import Foundation
import Kit
import KitTemplates

/// The actions on one snippet, in the list and in root search, and the few actions pages share.
struct SnippetActions {
    let feature: SnippetsFeature

    /// Paste first, so Return pastes, and Copy on Command-Return. The rest are grouped in the
    /// action panel. Built from what the library holds; no I/O.
    func actions(for snippet: Snippet) -> [Action] {
        let feature = feature
        let forms = SnippetForms(feature: feature)
        let id = snippet.id
        return delivery(for: snippet) + [
            .push(Strings.editAction, id: "edit", icon: .symbol("pencil"), shortcut: .edit) {
                .form(forms.editor(SnippetDraft(snippet), editing: id))
            }.with(section: Strings.snippetSection),
            .push(
                Strings.duplicateAction, id: "duplicate", icon: .symbol("plus.square.on.square"), shortcut: .duplicate
            ) {
                .form(forms.editor(Self.duplicate(snippet, in: feature.library.index)))
            }.with(section: Strings.snippetSection),
            Action(
                snippet.isPinned ? Strings.unpinAction : Strings.pinAction, id: "pin",
                icon: .symbol(snippet.isPinned ? "pin.slash" : "pin"), shortcut: .pin, section: Strings.snippetSection
            ) { context in
                try await feature.library.setPinned(!snippet.isPinned, id: id)
                context.showToast(
                    .success(snippet.isPinned ? Strings.unpinned(snippet.name) : Strings.pinned(snippet.name)))
                return .keepOpen
            },
            .push(Strings.createAction, id: "create", icon: .symbol("plus"), shortcut: .new) {
                .form(forms.editor(SnippetDraft(collection: snippet.collection ?? "")))
            }.with(section: Strings.librarySection),
            Action(
                Strings.deleteAction, id: "delete", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
                section: Strings.librarySection,
                confirmation: Confirmation(
                    Strings.deleteQuestion(snippet.name),
                    message: Strings.deleteMessage(includedBy: feature.library.index.includers(of: snippet.name)),
                    confirmTitle: Strings.deleteConfirm, isDestructive: true)
            ) { context in
                try await feature.library.remove(id: id)
                context.usage.forget(SnippetIDs.row(id))
                context.showToast(.success(Strings.deleted(snippet.name)))
                return .keepOpen
            },
        ]
    }

    /// Paste and Copy. Each renders when it runs, so `{date}` and `{clipboard}` are fresh. A snippet
    /// that asks for arguments shows a form for them first.
    private func delivery(for snippet: Snippet) -> [Action] {
        let feature = feature
        let id = snippet.id
        guard feature.library.index.arguments(of: id).isEmpty else {
            let forms = SnippetForms(feature: feature)
            return [
                Action(
                    Strings.pasteAction, id: "paste", icon: .symbol("doc.on.clipboard"), requires: [.accessibility]
                ) { _ in
                    .push(.form(forms.arguments(for: snippet, delivery: .paste)))
                }.recordingUse(),
                Action(Strings.copyAction, id: "copy", icon: .symbol("doc.on.doc"), shortcut: .secondaryAction) { _ in
                    .push(.form(forms.arguments(for: snippet, delivery: .copy)))
                }.recordingUse(),
            ]
        }
        return [
            Action.paste(title: Strings.pasteAction) { _ in
                try await feature.render(id: id).expansion
            }.recordingUse(),
            Action.copy(title: Strings.copyAction, hud: Strings.copiedHUD, shortcut: .secondaryAction) { _ in
                .text(try await feature.render(id: id).text)
            }.recordingUse(),
        ]
    }

    /// The editor's draft for a copy: a free name, and no keyword, since keywords are unique.
    static func duplicate(_ snippet: Snippet, in index: LibraryIndex) -> SnippetDraft {
        var draft = SnippetDraft(snippet)
        let name = Strings.copyName(snippet.name)
        let taken = Set(index.snippets.map(\.name))
        draft.name = taken.contains(name) ? SnippetImport.uniqueName(name, taken: taken) : name
        draft.keyword = ""
        return draft
    }

    /// Selects the snippets file in Finder.
    func showFile() -> Action {
        Action.reveal([feature.library.fileURL], title: Strings.showFileAction).with(id: "show-file")
    }

    /// Runs the host's grant flow for a permission expansion is missing, then starts expansion. The
    /// list's notice goes away through the library's change signal once expansion runs.
    func allow(_ permission: Permission) -> Action {
        let feature = feature
        return Action(Strings.allowAction(permission), id: "allow", icon: .symbol("lock.open"), requires: [permission])
        { _ in
            await feature.expansion.apply(feature.library.index).value
            return .keepOpen
        }
    }
}
