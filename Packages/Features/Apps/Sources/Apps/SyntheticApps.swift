import Foundation

/// A small tree of fake application bundles and Settings panes, for runs that must not read the
/// user's apps: scenarios, self-tests, benchmarks and tests. Each bundle holds only an Info.plist
/// and, when asked, localized names and search terms: everything the scan reads, nothing else.
nonisolated enum SyntheticApps {
    /// The library scenarios and self-tests see, over a tree written into `root` before the first
    /// scan.
    static func library(in root: URL) -> FolderAppLibrary {
        FolderAppLibrary(
            standardRoots: [
                AppScanRoot(root.appending(path: "Applications"), depth: 4),
                AppScanRoot(root.appending(path: "System/Applications"), depth: 2, isSystem: true),
            ],
            extensionsFolder: root.appending(path: "Extensions"), reader: BundleReader(languages: ["en"]),
            prepare: { writeDefaultTree(in: root) })
    }

    /// The bundle IDs ``SimulatedRunningApps`` pretends are running in scenarios.
    static let runningInScenarios = ["com.example.mail", "com.example.notes"]

    /// Writes the default tree once. Later calls find the marker and return.
    static func writeDefaultTree(in root: URL) {
        let marker = root.appending(path: "tree-version")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let apps = root.appending(path: "Applications")
        let system = root.appending(path: "System/Applications")
        let panes = root.appending(path: "Extensions")
        do {
            try writeApp(at: apps.appending(path: "Text Editor.app"), bundleID: "com.example.text-editor")
            try writeApp(at: apps.appending(path: "Web Browser.app"), bundleID: "com.example.browser")
            try writeApp(at: apps.appending(path: "Utilities/Disk Tool.app"), bundleID: "com.example.disk-tool")
            try writeApp(at: system.appending(path: "Mail.app"), bundleID: "com.example.mail")
            try writeApp(at: system.appending(path: "Notes.app"), bundleID: "com.example.notes")
            try writeApp(at: system.appending(path: "Calendar.app"), bundleID: "com.example.calendar")
            try writePane(
                at: panes.appending(path: "Network.appex"), id: "com.example.network-settings", name: "Network",
                anchors: [
                    Anchor(id: "DNS", titles: ["DNS servers"], index: "dns, domain, name server"),
                    Anchor(id: "Proxies", titles: ["Proxies"], index: "proxy, http, socks"),
                ])
            try writePane(
                at: panes.appending(path: "Sound.appex"), id: "com.example.sound-settings", name: "Sound",
                anchors: [Anchor(id: "output", titles: ["Output device"], index: "speakers, headphones")])
            try Data("1".utf8).write(to: marker)
        } catch {
            // A run without its synthetic apps still works; it shows no apps.
        }
    }

    /// One anchor of a fake pane's search terms.
    struct Anchor {
        var id: String
        var titles: [String]
        var index: String
    }

    /// Writes an application bundle with an Info.plist. `localized` maps a language to its
    /// `InfoPlist` strings; `asLoctable` writes them the way Apple's own bundles do, as one
    /// `InfoPlist.loctable`, instead of one `<language>.lproj/InfoPlist.strings` each.
    static func writeApp(
        at url: URL, bundleID: String?, info: [String: Any] = [:], localized: [String: [String: String]] = [:],
        asLoctable: Bool = false
    ) throws {
        var dictionary = info
        dictionary["CFBundlePackageType"] = "APPL"
        if let bundleID { dictionary["CFBundleIdentifier"] = bundleID }
        try writePlist(dictionary, to: url.appending(path: "Contents/Info.plist"))
        try writeLocalized(localized, table: "InfoPlist", asLoctable: asLoctable, in: url)
    }

    /// Writes a Settings extension with its search terms in English.
    static func writePane(
        at url: URL, id: String, name: String, anchors: [Anchor], allowsLinks: Bool = true,
        extensionPoint: String = SettingsPaneScanner.extensionPoint, localized: [String: [String: String]] = [:]
    ) throws {
        let termsFile = url.deletingPathExtension().lastPathComponent
        let info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleDisplayName": name, "CFBundleName": name,
            "CFBundleDevelopmentRegion": "en",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": extensionPoint,
                "SettingsExtensionAttributes": [
                    "allowsXAppleSystemPreferencesURLScheme": allowsLinks, "searchTermsFileName": termsFile,
                ],
            ],
        ]
        try writePlist(info, to: url.appending(path: "Contents/Info.plist"))
        try writeLocalized(localized, table: "InfoPlist", asLoctable: true, in: url)
        var terms: [String: Any] = [:]
        for anchor in anchors {
            terms[anchor.id] = [
                "localizableStrings": anchor.titles.map { ["title": $0, "index": anchor.index] }
            ]
        }
        try writePlist(terms, to: url.appending(path: "Contents/Resources/en.lproj/\(termsFile).searchTerms"))
    }

    static func writeLocalized(
        _ localized: [String: [String: String]], table: String, asLoctable: Bool, in bundle: URL
    ) throws {
        guard !localized.isEmpty else { return }
        let resources = bundle.appending(path: "Contents/Resources")
        if asLoctable {
            try writePlist(localized, to: resources.appending(path: table + ".loctable"))
            return
        }
        for (language, strings) in localized {
            let lines = strings.sorted { $0.key < $1.key }.map { "\"\($0.key)\" = \"\($0.value)\";" }
            let file = resources.appending(path: "\(language).lproj/\(table).strings")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // UTF-16 with a byte order mark, as Xcode writes .strings files for many apps.
            guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf16) else { continue }
            try data.write(to: file)
        }
    }

    static func writePlist(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url)
    }
}
