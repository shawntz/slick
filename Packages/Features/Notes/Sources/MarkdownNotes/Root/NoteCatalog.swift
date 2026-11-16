import Foundation
import Kit

/// Note titles in root search, while the setting is on. It is off by default; see
/// ``NotesSettings/showsInRootSearch``.
///
/// Rows are `.learnOnly`: root learns which note the user picks for a query, and the row comes back
/// only while this source offers it, so a deleted note never lingers.
final class NoteCatalog: CatalogSource {
    let namespace = NoteIDs.namespace
    private unowned let feature: NotesFeature

    init(feature: NotesFeature) {
        self.feature = feature
    }

    var changes: ChangeSignal? { feature.library.changes }

    var reloadsOnSettings: [AnySettingKey] { [NotesSettings.showsInRootSearch.erased] }

    func rows() async throws -> [Row] {
        guard feature.context.settings[NotesSettings.showsInRootSearch] else { return [] }
        let library = feature.library
        await library.ready()
        guard library.index.problem == nil else { return [] }
        return await NoteRows.all(library.index, pinned: library.pinned)
    }

    /// Built from the row's ID alone, so a row root search kept still works.
    func actions(for row: Row) -> [Action] {
        guard let fileName = NoteIDs.fileName(of: row) else { return [] }
        return feature.actions.actions(for: fileName, place: .root)
    }
}
