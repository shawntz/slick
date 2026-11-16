import Kit

/// A music app the feature can drive. The raw value is stored as the preferred player setting, so
/// it never changes.
nonisolated enum Player: String, SettingValue, CaseIterable, Hashable, Sendable {
    /// Apple's Music app.
    case music
    case spotify

    /// The bundle ID the app is found by while it runs, and the target of its Automation
    /// permission.
    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    /// The app's name, as its menu bar shows it.
    var name: String {
        switch self {
        case .music: Strings.Players.music
        case .spotify: Strings.Players.spotify
        }
    }

    /// The Automation permission that lets the feature send this app events.
    var permission: Permission { .automation(bundleID: bundleID) }

    /// The players in the order the feature tries them: the preferred one first, then the rest in
    /// declaration order.
    static func ordered(preferring preferred: Player) -> [Player] {
        [preferred] + allCases.filter { $0 != preferred }
    }
}
