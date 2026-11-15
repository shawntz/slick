import Kit

/// The Choose Folders to Search page: one row per protected place with where it stands, and a row
/// that asks for all the folders at once. Each row's action asks macOS only when the user runs it.
final class PlacesList: ListSource {
    static let namespace = "files.place"
    static let allKey = "all"

    private unowned let feature: FileSearchFeature

    init(feature: FileSearchFeature) {
        self.feature = feature
    }

    var changes: ChangeSignal? { feature.controller.stateChanges }

    var reloadsOnSettings: [AnySettingKey] {
        [
            FileSearchSettings.includedPlaces.erased, FileSearchSettings.turnedOffPlaces.erased,
            FileSearchSettings.deniedPlaces.erased,
        ]
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        let states = feature.placeStates()
        func row(_ place: ProtectedPlace) -> Row {
            let state = states[place] ?? .notSearched
            return Row(
                id: ItemID(Self.namespace, place.rawValue), title: Strings.Places.name(place),
                subtitle: Strings.Places.explanation(place, state), icon: .symbol(Self.symbol(for: place)),
                accessories: [.tag(Strings.Places.tag(state), color: Self.color(for: state))], memory: .never)
        }
        let all = Row(
            id: ItemID(Self.namespace, Self.allKey), title: Strings.Places.allTitle,
            subtitle: Strings.Places.allSubtitle,
            icon: .symbol("folder.badge.plus"), memory: .never)
        return ListResult(sections: [
            ListSection(Strings.Places.foldersSection, id: "folders", rows: [all] + ProtectedPlace.folders.map(row)),
            ListSection(
                Strings.Places.volumesSection, id: "volumes", rows: [row(.removableVolumes), row(.networkVolumes)]),
        ])
    }

    func actions(for row: Row) -> [Action] {
        if row.id.key == Self.allKey { return [feature.searchAllAction()] }
        guard let place = ProtectedPlace(rawValue: row.id.key) else { return [] }
        return feature.placeActions(for: place)
    }

    static func symbol(for place: ProtectedPlace) -> String {
        switch place {
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .iCloudDrive: "icloud"
        case .removableVolumes: "externaldrive"
        case .networkVolumes: "network"
        }
    }

    static func color(for state: PlaceState) -> KitColor? {
        switch state {
        case .searched: .green
        case .waitingForAccess, .accessDenied: .orange
        case .notSearched, .turnedOff: nil
        }
    }
}
