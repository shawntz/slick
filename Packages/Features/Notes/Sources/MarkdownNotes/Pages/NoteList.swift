import Foundation
import Kit

/// The Search Notes page.
///
/// The source filters, because people search the text of their notes and not only the titles. A
/// search runs off the main thread over text read when the notes were scanned, so typing never
/// waits on the disk. Opening the page lists the folder again, so a note changed while nothing
/// watched shows its new text.
final class NoteList: ListSource {
    private unowned let feature: NotesFeature

    init(feature: NotesFeature) {
        self.feature = feature
    }

    let filtering = ListFiltering.custom(debounce: .milliseconds(40))

    var changes: ChangeSignal? { feature.library.changes }

    func load(_ request: ListRequest) async throws -> ListResult {
        let library = feature.library
        await library.ready()
        if request.reason == .open { await library.rescan() }
        try Task.checkCancellation()
        let index = library.index
        let query = NoteQuery(request.query)
        let sections = try await NoteRows.sections(
            index, pinned: library.pinned, query: query,
            days: DaySections(clock: feature.context.clock, direction: .past))
        try Task.checkCancellation()
        return ListResult(
            sections: sections, emptyState: emptyState(index, query: query), notice: feature.notice(for: index))
    }

    func detail(for row: Row) async throws -> Detail? {
        let library = feature.library
        guard let fileName = NoteIDs.fileName(of: row), let note = library.index.note(named: fileName) else {
            return nil
        }
        // A note only in the cloud is not read here, which would download it.
        let read =
            note.isDataless ? .failure(Strings.notDownloaded) : await NoteDetailSource.read(fileName, library: library)
        try Task.checkCancellation()
        return await NoteDetail.make(
            note, read: read, isPinned: library.pinned.contains(fileName), limits: library.limits,
            locale: feature.context.clock.locale)
    }

    func actions(for row: Row) -> [Action] {
        guard let fileName = NoteIDs.fileName(of: row) else { return [] }
        return feature.actions.actions(for: fileName, place: .list)
    }

    private func emptyState(_ index: NoteIndex, query: NoteQuery) -> EmptyState {
        if let problem = index.problem {
            return EmptyState(
                icon: .symbol("exclamationmark.triangle"), title: Strings.notReadTitle,
                message: Strings.problemMessage(problem, folder: index.folder),
                actions: feature.problemActions(for: index).emptyState)
        }
        if !query.isEmpty {
            return EmptyState(
                icon: .symbol("magnifyingglass"), title: Strings.noMatchesTitle, message: Strings.noMatchesMessage,
                actions: [createAction(body: query.words.joined(separator: " "))])
        }
        return EmptyState(
            icon: .symbol("note.text"), title: Strings.emptyTitle, message: Strings.emptyMessage,
            actions: [createAction(body: "")])
    }

    private func createAction(body: String) -> Action {
        let forms = feature.forms
        return Action(Strings.createCommand, id: "create", icon: .symbol("plus")) { _ in
            .push(.form(forms.create(body: body)))
        }
    }
}
