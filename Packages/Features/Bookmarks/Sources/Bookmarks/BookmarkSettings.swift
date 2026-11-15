import Kit

/// The feature's settings. `nonisolated`, so code off the main actor can read them too.
nonisolated enum BookmarkSettings {
    /// Whether the user chose to search a browser's bookmarks. Every browser starts off: nothing is
    /// read until the user switches one on.
    static func includes(_ browser: Browser) -> SettingKey<Bool> {
        SettingKey("browser." + browser.rawValue, default: false)
    }

    /// Whether Safari's Reading List shows with its bookmarks.
    static let includesReadingList = SettingKey("includesReadingList", default: true)

    /// Whether bookmarks join root search. Off until the user turns it on, so root search stays as
    /// it was when a browser is chosen.
    static let showsInRootSearch = SettingKey("showsInRootSearch", default: false)

    /// Where Return opens a bookmark. Command-Return opens it in the other place.
    static let opensIn = SettingKey("opensIn", default: OpenTarget.defaultBrowser)

    /// The settings whose change means the bookmarks must be read again.
    static var sourceKeys: [AnySettingKey] {
        Browser.allCases.map { includes($0).erased } + [includesReadingList.erased]
    }

    /// The browsers the user switched on, in order.
    static func chosenBrowsers(_ settings: FeatureSettings) -> [Browser] {
        Browser.allCases.filter { settings[includes($0)] }
    }
}

/// Where Return opens a bookmark.
nonisolated enum OpenTarget: String, CaseIterable, SettingValue {
    case defaultBrowser
    case sourceBrowser
}
