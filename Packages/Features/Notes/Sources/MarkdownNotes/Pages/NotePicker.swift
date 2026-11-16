import Foundation
import Kit

/// The notes to choose from for Append to Note. The host filters it by title and tag; Return adds
/// the text the user typed to the chosen note, or asks for the text when there is none.
final class NotePicker: ListSource {
    private unowned let feature: NotesFeature
    /// The text to add, as typed in the command's argument or in quick capture.
    let text: String

    init(feature: NotesFeature, text: String) {
        self.feature = feature
        self.text = text
    }

    var changes: ChangeSignal? { feature.library.changes }

    func load(_ request: ListRequest) async throws -> ListResult {
        let library = feature.library
        await library.ready()
        let rows = await NoteRows.all(library.index, pinned: library.pinned)
        return ListResult(sections: [ListSection(rows: rows)], notice: feature.notice(for: library.index))
    }

    func actions(for row: Row) -> [Action] {
        let library = feature.library
        guard let fileName = NoteIDs.fileName(of: row), let note = library.index.note(named: fileName) else {
            return []
        }
        let forms = feature.forms
        let text = text
        let title = DisplayText.fileName(note.title)
        return [
            Action(Strings.appendTitle(title), id: "append", icon: .symbol("text.append")) { _ in
                guard NoteText.isVisible(text[...]) else {
                    return .push(.form(forms.append(to: fileName, title: note.title)))
                }
                _ = try await library.append(text, to: fileName)
                return .close(hud: .success(Strings.appended(title)))
            }
        ]
    }
}
