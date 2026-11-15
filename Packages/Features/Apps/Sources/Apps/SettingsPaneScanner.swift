import Foundation

/// Finds the System Settings panes and their anchors in the folder of ExtensionKit extensions.
/// Synchronous and file-bound: call it only from a `@concurrent` function.
///
/// On macOS 27 every pane is an app extension in `/System/Library/ExtensionKit/Extensions` whose
/// extension point is `com.apple.Settings.extension.ui`. Its anchors are the top-level keys of a
/// localized `<name>.searchTerms` property list, whose titles and index words are the vocabulary
/// System Settings searches itself. The lab found 52 panes and 499 anchors among 289 extensions.
///
/// Why a scan and not a table bundled with the app: the names and search words exist in every
/// language only on the system, a table would go stale with each macOS release, and 499 anchors are
/// too many to keep by hand. The scan reads property lists directly, off the main thread, once per
/// launch; the lab's 227 ms went to loading `Bundle` objects, which this scan avoids.
nonisolated struct SettingsPaneScanner {
    var reader: BundleReader

    static let extensionPoint = "com.apple.Settings.extension.ui"

    /// Panes whose own name is wrong for people, with the key of the right name in the pane's
    /// `Localizable` strings and a fallback. Battery's extension is called "PowerPreferences" and keeps
    /// the sidebar title under another key. The headphone pane is named after the connected
    /// headphones at run time, so it gets a fixed name.
    static let nameOverrides: [String: (key: String?, fallback: String)] = [
        "com.apple.Battery-Settings.extension": ("BATTERY_PREF_TITLE", "Battery"),
        "com.apple.HeadphoneSettings": (nil, "Headphones"),
    ]

    /// Panes that open nothing a person would look for.
    static let skipped: Set<String> = ["com.apple.FollowUpSettings.FollowUpSettingsExtension"]

    /// At most this many index words per anchor. Accessibility's lists run to dozens of words, and
    /// every word is one more way for an unrelated query to match.
    static let keywordLimit = 24

    /// Every pane in the folder that allows deep links, sorted by name.
    func scan(folder: URL) -> [SystemSettingsPane] {
        var panes: [String: SystemSettingsPane] = [:]
        for entry in DirectoryEntries(folder.path) where entry.name.hasSuffix(".appex") {
            let path = folder.path + "/" + entry.name
            guard let pane = pane(at: path), panes[pane.id] == nil else { continue }
            panes[pane.id] = pane
        }
        return panes.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func pane(at path: String) -> SystemSettingsPane? {
        guard let info = reader.infoDictionary(ofBundleAt: path),
            let id = info["CFBundleIdentifier"] as? String, !Self.skipped.contains(id),
            let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
            attributes["EXExtensionPointIdentifier"] as? String == Self.extensionPoint
        else { return nil }
        let settings = attributes["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
        guard settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true else { return nil }
        let region = info["CFBundleDevelopmentRegion"] as? String
        let name = name(of: id, info: info, path: path, developmentRegion: region)
        var anchors: [SystemSettingsPane.Anchor] = []
        if let file = settings["searchTermsFileName"] as? String, !file.isEmpty {
            let terms = reader.localizedTable(file, suffix: "searchTerms", inBundleAt: path, developmentRegion: region)
            anchors = Self.anchors(from: terms, paneName: name)
        }
        return SystemSettingsPane(id: id, name: name, path: path, anchors: anchors)
    }

    private func name(of id: String, info: [String: Any], path: String, developmentRegion: String?) -> String {
        if let override = Self.nameOverrides[id] {
            guard let key = override.key else { return override.fallback }
            let table = reader.localizedTable("Localizable", inBundleAt: path, developmentRegion: developmentRegion)
            return (table[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? override.fallback
        }
        let localized = reader.localizedTable("InfoPlist", inBundleAt: path, developmentRegion: developmentRegion)
        return AppNaming.name(localized: localized, info: info, fileName: AppScanner.fileName(of: path))
    }

    /// One anchor per top-level key, titled by its first title. Its other titles and the index words
    /// become keywords. An anchor titled like its pane, or like an earlier anchor, adds nothing and is
    /// left out.
    static func anchors(from terms: [String: Any], paneName: String) -> [SystemSettingsPane.Anchor] {
        var seenTitles: Set<String> = [paneName.lowercased()]
        var anchors: [SystemSettingsPane.Anchor] = []
        for anchorID in terms.keys.sorted() {
            let entries = (terms[anchorID] as? [String: Any])?["localizableStrings"] as? [[String: Any]] ?? []
            let titles = entries.compactMap { ($0["title"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let title = titles.first, seenTitles.insert(title.lowercased()).inserted else { continue }
            var keywords: [String] = []
            var seenWords: Set<String> = [title.lowercased()]
            let words = entries.flatMap { ($0["index"] as? String ?? "").split(separator: ",").map(String.init) }
            for word in Array(titles.dropFirst()) + words {
                let trimmed = word.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, keywords.count < keywordLimit, seenWords.insert(trimmed.lowercased()).inserted {
                    keywords.append(trimmed)
                }
            }
            anchors.append(SystemSettingsPane.Anchor(id: anchorID, title: title, keywords: keywords))
        }
        return anchors
    }
}

/// The deep links that open a pane or an anchor: `x-apple.systempreferences:<pane id>[?<anchor>]`.
/// The lab verified the form against System Settings on macOS 27.2.
nonisolated enum SettingsLink {
    static let scheme = "x-apple.systempreferences"

    /// The row key for a pane, or for an anchor inside it.
    static func key(pane: String, anchor: String? = nil) -> String {
        anchor.map { pane + "?" + $0 } ?? pane
    }

    /// The link a row key opens. Anchor names may hold spaces, as Network's "Advanced Ethernet"
    /// does, so the anchor is percent-encoded.
    static func url(forKey key: String) -> URL? {
        let parts = key.split(separator: "?", maxSplits: 1).map(String.init)
        guard let pane = parts.first, !pane.isEmpty else { return nil }
        var link = scheme + ":" + pane
        if parts.count == 2 {
            guard let anchor = parts[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }
            link += "?" + anchor
        }
        return URL(string: link)
    }
}
