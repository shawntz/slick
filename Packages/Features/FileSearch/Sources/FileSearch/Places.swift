import Foundation
import Kit

/// A place macOS guards with its own prompt on the first read. The feature reads one only after the
/// user asked for it. Full Disk Access only spares the prompt: it never brings a place in by itself,
/// because the user may have granted it for another feature, such as Safari bookmarks.
nonisolated enum ProtectedPlace: String, CaseIterable, Hashable, Sendable {
    case desktop
    case documents
    case downloads
    case iCloudDrive = "icloud-drive"
    case removableVolumes = "removable-volumes"
    case networkVolumes = "network-volumes"

    /// The folders in the home folder, which "all at once" includes.
    static let folders: [ProtectedPlace] = [.desktop, .documents, .downloads, .iCloudDrive]

    /// The permission that stands for the place. iCloud Drive has none in Kit: macOS asks when the
    /// folder is first read, and the read tells whether it was allowed.
    var permission: Permission? {
        switch self {
        case .desktop: .protectedFolder(.desktop)
        case .documents: .protectedFolder(.documents)
        case .downloads: .protectedFolder(.downloads)
        case .iCloudDrive: nil
        case .removableVolumes: .protectedFolder(.removableVolumes)
        case .networkVolumes: .protectedFolder(.networkVolumes)
        }
    }

    /// The place's folder below `home`, or nil for volumes.
    func folder(home: String) -> String? {
        switch self {
        case .desktop: home + "/Desktop"
        case .documents: home + "/Documents"
        case .downloads: home + "/Downloads"
        case .iCloudDrive: home + "/Library/Mobile Documents/com~apple~CloudDocs"
        case .removableVolumes, .networkVolumes: nil
        }
    }

    /// Places named by stored raw values, unknown names dropped.
    static func set(_ names: [String]) -> Set<ProtectedPlace> {
        Set(names.compactMap(ProtectedPlace.init(rawValue:)))
    }

    /// Stored raw values in a stable order.
    static func names(_ places: Set<ProtectedPlace>) -> [String] {
        allCases.filter(places.contains).map(\.rawValue)
    }
}

/// Where one protected place stands.
nonisolated enum PlaceState: Hashable, Sendable {
    /// Not asked for. Full Disk Access alone never changes this.
    case notSearched
    /// In the index.
    case searched
    /// The user asked for it, and its permission is missing.
    case waitingForAccess
    /// The user asked for it, and reading it failed. Not read again until the user asks again.
    case accessDenied
    /// The user asked not to search it.
    case turnedOff

    var isSearched: Bool { self == .searched }
}

/// What the user chose for the protected places and what reading them found, as kept in settings.
nonisolated struct PlaceChoices: Hashable, Sendable {
    var included: Set<ProtectedPlace> = []
    var turnedOff: Set<ProtectedPlace> = []
    var denied: Set<ProtectedPlace> = []

    init(included: Set<ProtectedPlace> = [], turnedOff: Set<ProtectedPlace> = [], denied: Set<ProtectedPlace> = []) {
        self.included = included
        self.turnedOff = turnedOff
        self.denied = denied
    }

    init(_ settings: FeatureSettings) {
        included = ProtectedPlace.set(settings[FileSearchSettings.includedPlaces])
        turnedOff = ProtectedPlace.set(settings[FileSearchSettings.turnedOffPlaces])
        denied = ProtectedPlace.set(settings[FileSearchSettings.deniedPlaces])
    }

    /// Writes the choices back. Only keys whose value changed are written, so an unchanged choice
    /// sends no settings change.
    func save(to settings: FeatureSettings) {
        let values = [
            (FileSearchSettings.includedPlaces, ProtectedPlace.names(included)),
            (FileSearchSettings.turnedOffPlaces, ProtectedPlace.names(turnedOff)),
            (FileSearchSettings.deniedPlaces, ProtectedPlace.names(denied)),
        ]
        for (key, value) in values where settings[key] != value {
            settings[key] = value
        }
    }

    /// The user asked to search these places: they leave the turned-off and refused lists.
    mutating func include(_ places: [ProtectedPlace]) {
        for place in places {
            included.insert(place)
            turnedOff.remove(place)
            denied.remove(place)
        }
    }

    /// The user asked not to search this place.
    mutating func turnOff(_ place: ProtectedPlace) {
        included.remove(place)
        denied.remove(place)
        turnedOff.insert(place)
    }

    /// Where `place` stands, given the permissions now. Reading statuses never prompts.
    func state(
        of place: ProtectedPlace, isGranted: (Permission) -> Bool, fullDiskAccess: Bool
    ) -> PlaceState {
        if turnedOff.contains(place) { return .turnedOff }
        if denied.contains(place) { return .accessDenied }
        // Only the user's own choice brings a place in. Full Disk Access may have been granted for
        // another feature, and reading Documents because of it would read personal data no one
        // asked File Search to read.
        guard included.contains(place) else { return .notSearched }
        guard let permission = place.permission else { return .searched }
        return fullDiskAccess || isGranted(permission) ? .searched : .waitingForAccess
    }

    /// Every place's state.
    func states(isGranted: (Permission) -> Bool, fullDiskAccess: Bool) -> [ProtectedPlace: PlaceState] {
        var states: [ProtectedPlace: PlaceState] = [:]
        for place in ProtectedPlace.allCases {
            states[place] = state(of: place, isGranted: isGranted, fullDiskAccess: fullDiskAccess)
        }
        return states
    }
}
