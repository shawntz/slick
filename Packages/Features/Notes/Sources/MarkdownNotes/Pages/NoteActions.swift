import Foundation
import Kit

/// The actions of a note, wherever it shows: the Search Notes list, a note's own page, or root
/// search. Built from the file name and what the last scan holds, so building them reads nothing.
/// Each action reads or checks the file when it runs, off the main thread.
///
/// Return edits the note in the list and shows it from root search; Command-Return opens it in the
/// default editor everywhere.
final class NoteActions {
    /// Where the actions show, which decides the first action and what happens after a delete.
    enum Place {
        /// The Search Notes list, whose detail pane already shows the note.
        case list
        /// Root search, where the first action shows the note.
        case root
        /// A note's own page, which goes back after a delete.
        case page
    }

    private unowned let feature: NotesFeature

    init(feature: NotesFeature) {
        self.feature = feature
    }

    func actions(for fileName: String, place: Place) -> [Action] {
        let library = feature.library
        guard let note = library.index.note(named: fileName) else { return [] }
        let forms = feature.forms
        let feature = feature
        let title = note.title
        let isPinned = library.pinned.contains(fileName)
        var actions: [Action] = []
        if place == .root {
            actions.append(
                Action(Strings.showNote, id: "show", icon: .symbol("doc.text")) { _ in
                    .push(feature.notePage(fileName))
                })
        }
        actions += [
            Action(Strings.editNote, id: "edit", icon: .symbol("pencil"), shortcut: .edit) { _ in
                let read = try await library.readForChange(fileName)
                let original = await NoteWork.parse(read.text)
                return .push(
                    .form(
                        forms.edit(
                            fileName, original: original, version: read.version, byteOrderMark: read.byteOrderMark)))
            },
            Action(Strings.openInEditor, id: "open", icon: .symbol("arrow.up.forward.app"), shortcut: .secondaryAction)
            {
                context in
                let file = try await library.liveFile(fileName)
                context.dismiss()
                try await context.workspace.open(file)
                return .close()
            },
            Action.copy(title: Strings.copyMarkdown, hud: Strings.copiedMarkdown, shortcut: .copy) { _ in
                .text(try await library.wholeText(fileName))
            }
            .with(id: "copy-markdown"),
            Action.copy(
                title: Strings.copyPlainText, hud: Strings.copiedPlainText,
                shortcut: KeyCombo(.c, [.option, .shift, .command])
            ) { _ in
                .text(await NoteWork.plainText(try await library.wholeText(fileName)))
            }
            .with(id: "copy-plain-text"),
            Action.paste(title: Strings.pasteNote) { _ in
                .text(try await library.wholeText(fileName))
            },
            Action(
                isPinned ? Strings.unpinNote : Strings.pinNote, id: "pin",
                icon: .symbol(isPinned ? "pin.slash" : "pin"),
                shortcut: .pin
            ) { context in
                let pin = !library.pinned.contains(fileName)
                try await library.setPinned(pin, fileName: fileName)
                context.showToast(.success(pin ? Strings.pinned : Strings.unpinned))
                return .keepOpen
            },
            Action(
                Strings.renameNote, id: "rename", icon: .symbol("character.cursor.ibeam"),
                shortcut: KeyCombo(.r, [.shift, .command])
            ) { _ in
                let read = try await library.readForChange(fileName)
                return .push(.form(forms.rename(fileName, title: await NoteWork.parse(read.text).title)))
            },
            Action(Strings.duplicateNote, id: "duplicate", icon: .symbol("plus.square.on.square"), shortcut: .duplicate)
            {
                context in
                let copy = try await library.duplicate(fileName)
                context.showToast(
                    Toast(
                        .success, Strings.duplicated(title),
                        action: ToastAction(Strings.editCopy) { _ in
                            let read = try await library.readForChange(copy)
                            let original = await NoteWork.parse(read.text)
                            return .push(
                                .form(
                                    forms.edit(
                                        copy, original: original, version: read.version,
                                        byteOrderMark: read.byteOrderMark)))
                        }))
                return .keepOpen
            },
            Action(Strings.showInFinder, id: "reveal", icon: .symbol("folder"), shortcut: .reveal) { context in
                await context.workspace.reveal([try await library.liveFile(fileName)])
                return .close()
            },
            trash(fileName, title: title, place: place),
        ]
        if place == .list {
            actions.append(
                Action.runCommand(
                    NoteIDs.command(NoteIDs.createCommand), title: Strings.createCommand, icon: .symbol("plus")
                )
                .with(shortcut: .new))
        }
        return actions
    }

    /// Moves the note's file to the Trash after a question that names it. The file is checked again
    /// on disk just before, so a row that went stale cannot trash something else.
    private func trash(_ fileName: String, title: String, place: Place) -> Action {
        let library = feature.library
        return Action(
            Strings.moveToTrash, id: "move-to-trash", icon: .symbol("trash"), shortcut: .remove, style: .destructive,
            confirmation: Confirmation(
                Strings.trashQuestion(DisplayText.fileName(title)), message: Strings.trashMessage,
                confirmTitle: Strings.moveToTrash, isDestructive: true)
        ) { context in
            let url = try await library.liveFile(fileName)
            _ = try await context.workspace.moveToTrash([url])
            context.usage.forget(NoteIDs.row(fileName))
            await library.didRemove(fileName)
            context.showToast(.success(Strings.movedToTrash))
            return place == .page ? .pop : .keepOpen
        }
    }
}
