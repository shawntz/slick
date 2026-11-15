import Kit

/// People in root search, by name, with nicknames and companies as keywords. It has rows only
/// while the user allowed access and kept the setting on. Rows are `.learnOnly`: root learns which
/// person a query leads to, by ID, and keeps no copy of the row.
@MainActor final class PeopleCatalog: CatalogSource {
    let namespace = PeopleSnapshot.namespace
    private let directory: PeopleDirectory
    private let builder: PeopleActions
    private let settings: FeatureSettings

    init(directory: PeopleDirectory, actions: PeopleActions, settings: FeatureSettings) {
        self.directory = directory
        self.builder = actions
        self.settings = settings
    }

    var changes: ChangeSignal? { directory.changes }

    var reloadsOnSettings: [AnySettingKey] { [PeopleSettings.showsInRootSearch.erased] }

    /// Every person, or nothing when the setting is off or access is missing. Never asks for
    /// access, and never calls the store without it.
    func rows() async throws -> [Row] {
        guard settings[PeopleSettings.showsInRootSearch] else { return [] }
        do {
            return try await directory.current().catalogRows
        } catch PeopleError.accessMissing {
            directory.announcesNextRead = true
            return []
        }
    }

    func actions(for row: Row) -> [Action] {
        builder.actions(for: row)
    }
}
