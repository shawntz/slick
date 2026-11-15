import Foundation

/// How an app is named and what else it answers to.
nonisolated enum AppNaming {
    /// The name of a bundle that has no file name people see, such as a System Settings pane: the
    /// localized display name, then the Info.plist display name, then the bundle name, then the file
    /// name without its extension. Apps are named by ``finderName(localized:info:fileName:)`` instead.
    static func name(localized: [String: Any], info: [String: Any], fileName: String) -> String {
        let candidates = [
            localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"],
            info["CFBundleName"],
        ]
        for case let name as String in candidates {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fileName
    }

    /// The name Finder shows for an app, worked out from the bundle's own files by the system's
    /// rule: the localized display name while the file name equals the name in the Info.plist, else
    /// the file name. The name in the Info.plist is `CFBundleDisplayName`, or `CFBundleName` when
    /// the bundle has no display name, as Activity Monitor does. A bundle renamed on disk, or one
    /// named "Code" in a file named "Code Studio.app", shows its file name.
    ///
    /// Why not ask the system: asking for a file's localized name makes LaunchServices register the
    /// bundle, with a synchronous call to its daemon that can stall for minutes, and a test's
    /// made-up apps would be registered on the developer's Mac.
    static func finderName(localized: [String: Any], info: [String: Any], fileName: String) -> String {
        let listed = shownText(info["CFBundleDisplayName"]) ?? shownText(info["CFBundleName"])
        guard listed == fileName else { return fileName }
        return shownText(localized["CFBundleDisplayName"]) ?? shownText(localized["CFBundleName"]) ?? fileName
    }

    /// A name from a property list as people read it: trimmed, and without the soft hyphens some
    /// localizations put inside long words, which would split the word for search. Nil when empty.
    static func shownText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.replacing("\u{00AD}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Everything the app answers to besides its name: its other bundle names, the file name, the
    /// alternate names the bundle declares, such as "System Preferences" for System Settings, and
    /// the well-known alternates below. Each once, ignoring case, never the name itself.
    static func keywords(name: String, localized: [String: Any], info: [String: Any], fileName: String) -> [String] {
        var candidates: [String] = [fileName]
        for case let other as String in [
            localized["CFBundleDisplayName"], localized["CFBundleName"], info["CFBundleDisplayName"],
            info["CFBundleName"],
        ] {
            candidates.append(other)
        }
        candidates += info["CFBundleAlternateNames"] as? [String] ?? []
        if let bundleID = info["CFBundleIdentifier"] as? String {
            candidates += alternates[bundleID] ?? []
        }
        var seen: Set<String> = [name.lowercased()]
        var keywords: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted {
                keywords.append(trimmed)
            }
        }
        return keywords
    }

    /// Words people type for an app that appear nowhere in its bundle: old names, generic names and
    /// the names of the equivalent app on other systems. Spotlight ships a few such synonyms of its
    /// own; this table covers the common cases. Keyed by bundle ID.
    static let alternates: [String: [String]] = [
        "com.apple.ActivityMonitor": ["task manager", "processes"],
        "com.apple.AddressBook": ["address book"],
        "com.apple.AppStore": ["mac app store"],
        "com.apple.calculator": ["calc"],
        "com.apple.Console": ["logs"],
        "com.apple.DigitalColorMeter": ["color picker", "eyedropper"],
        "com.apple.DiskUtility": ["format disk", "partition"],
        "com.apple.finder": ["files", "file manager", "explorer"],
        "com.apple.FontBook": ["fonts"],
        "com.apple.iBooksX": ["ibooks", "ebooks"],
        "com.apple.iCal": ["ical", "schedule"],
        "com.apple.iWork.Keynote": ["presentation", "slides"],
        "com.apple.iWork.Numbers": ["spreadsheet"],
        "com.apple.iWork.Pages": ["word processor"],
        "com.apple.keychainaccess": ["passwords", "certificates"],
        "com.apple.mail": ["email"],
        "com.apple.MobileSMS": ["imessage", "sms", "texts"],
        "com.apple.Music": ["itunes"],
        "com.apple.Notes": ["notepad"],
        "com.apple.Photos": ["iphoto", "pictures"],
        "com.apple.PhotoBooth": ["camera", "webcam"],
        "com.apple.Preview": ["pdf viewer", "image viewer"],
        "com.apple.QuickTimePlayerX": ["video player", "screen recording"],
        "com.apple.reminders": ["todo", "tasks"],
        "com.apple.Safari": ["browser", "web"],
        "com.apple.ScriptEditor2": ["applescript"],
        "com.apple.shortcuts": ["automation", "workflows"],
        "com.apple.systempreferences": ["control panel"],
        "com.apple.Terminal": ["shell", "console", "command line"],
        "com.apple.TextEdit": ["text editor", "notepad"],
        "com.apple.VoiceMemos": ["recorder", "audio recording"],
        "com.google.Chrome": ["browser"],
        "com.microsoft.VSCode": ["vscode", "visual studio code"],
        "org.mozilla.firefox": ["browser"],
    ]
}
