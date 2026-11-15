import Foundation
import Kit

/// A browser whose bookmarks the feature can read. The order is the order of settings, the filter
/// dropdown and the list.
nonisolated enum Browser: String, CaseIterable, Codable, Hashable, Sendable {
    case safari
    case chrome
    case brave
    case edge
    case vivaldi
    case opera
    case chromium
    case firefox

    /// How the browser stores its bookmarks.
    enum Format: Hashable, Sendable {
        /// `~/Library/Safari/Bookmarks.plist`, with the Reading List inside.
        case safariPropertyList
        /// A `Bookmarks` JSON file in each profile folder.
        case chromiumJSON
        /// `places.sqlite` in each profile folder.
        case firefoxPlaces
    }

    var format: Format {
        switch self {
        case .safari: .safariPropertyList
        case .chrome, .brave, .edge, .vivaldi, .opera, .chromium: .chromiumJSON
        case .firefox: .firefoxPlaces
        }
    }

    /// The app, for its icon and for opening a bookmark where it came from.
    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .chromium: "org.chromium.Chromium"
        case .firefox: "org.mozilla.firefox"
        }
    }

    /// The browser's folder, relative to the home folder.
    var dataFolder: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .opera: "Library/Application Support/com.operasoftware.Opera"
        case .chromium: "Library/Application Support/Chromium"
        case .firefox: "Library/Application Support/Firefox/Profiles"
        }
    }

    /// True when macOS keeps the browser's files behind Full Disk Access.
    var needsFullDiskAccess: Bool { self == .safari }

    var name: String { Strings.browserName(self) }

    /// The browser's place in ``allCases``.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One browser profile with bookmarks: where its files are and what to call it.
nonisolated struct BrowserProfile: Hashable, Sendable, Codable {
    var browser: Browser
    /// The profile's folder name, such as "Default" or "Profile 2". Empty for Safari and for a
    /// browser that keeps one profile in its own folder. Row IDs are built from it, so it must not
    /// change between launches.
    var key: String
    /// The files to read, the main one first. Files that do not exist are skipped.
    var files: [URL]

    init(browser: Browser, key: String, files: [URL]) {
        self.browser = browser
        self.key = key
        self.files = files
    }

    /// Unique across browsers: `chrome/Profile 2`, or `safari`.
    var id: String { key.isEmpty ? browser.rawValue : browser.rawValue + "/" + key }

    /// What the dropdown and the row call the profile. Taken from the folder name, because the
    /// names people give profiles live in other files the feature does not read.
    var name: String { Strings.profileName(folder: key, browser: browser) }
}
