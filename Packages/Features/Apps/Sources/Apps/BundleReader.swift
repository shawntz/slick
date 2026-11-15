import Foundation

/// Reads what the scan needs from a bundle on disk: its Info.plist and the localized strings for the
/// user's languages. Synchronous file reads, so call it only from a `@concurrent` function.
///
/// It reads the files directly instead of making a `Bundle`, which the lab measured at 0.4 ms per app
/// cold and which Foundation caches for the life of the process, so an app updated in place would
/// keep its old name.
nonisolated struct BundleReader: Sendable {
    /// The user's preferred languages, best first, such as `["de-DE", "en"]`.
    var languages: [String]
    /// The bundle's `Contents/Info.plist`, or nil when it has none. An iOS app installed on a Mac
    /// keeps its Info.plist inside `WrappedBundle`, which is tried second.
    func infoDictionary(ofBundleAt path: String) -> [String: Any]? {
        Self.plist(at: path + "/Contents/Info.plist") ?? Self.plist(at: path + "/WrappedBundle/Info.plist")
    }

    /// The bundle's strings in `table` for the best of the user's languages: from `<table>.loctable`,
    /// the single-file form Apple's own bundles use, or else `<language>.lproj/<table>.<suffix>`.
    /// Empty when the bundle has no such table.
    func localizedTable(
        _ table: String, suffix: String = "strings", inBundleAt path: String, developmentRegion: String?
    ) -> [String: Any] {
        let resources = path + "/Contents/Resources"
        let entries = Self.entries(of: resources)
        if entries.contains(table + ".loctable"),
            let byLanguage = Self.plist(at: resources + "/" + table + ".loctable"),
            let language = best(of: Array(byLanguage.keys), developmentRegion: developmentRegion),
            let strings = byLanguage[language] as? [String: Any]
        {
            return strings
        }
        let languages = entries.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
        guard let language = best(of: languages, developmentRegion: developmentRegion) else { return [:] }
        return Self.plist(at: resources + "/" + language + ".lproj/" + table + "." + suffix) ?? [:]
    }

    /// The localization among `available` that suits the user best, else the development region.
    func best(of available: [String], developmentRegion: String?) -> String? {
        guard !available.isEmpty else { return nil }
        if let match = Bundle.preferredLocalizations(from: available, forPreferences: languages).first {
            return match
        }
        if let developmentRegion, available.contains(developmentRegion) { return developmentRegion }
        return available.contains("en") ? "en" : available.first
    }

    /// A property list file as a dictionary. Old-style `.strings` files, UTF-8 or UTF-16, parse too.
    static func plist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The names in a folder, without "." and "..". Empty when it cannot be read.
    static func entries(of folder: String) -> [String] {
        DirectoryEntries(folder).map(\.name)
    }
}

/// The entries of one folder through `readdir`, with the file type the directory already holds.
/// The lab measured a scan of every app folder at 0.6 ms this way, against 2.8 ms through
/// `FileManager.contentsOfDirectory`.
nonisolated struct DirectoryEntries: Sequence {
    struct Entry {
        var name: String
        /// The type from the directory entry: `DT_DIR`, `DT_LNK`, `DT_REG`, or `DT_UNKNOWN` on file
        /// systems that do not record it.
        var type: UInt8
    }

    let folder: String

    init(_ folder: String) {
        self.folder = folder
    }

    func makeIterator() -> AnyIterator<Entry> {
        var entries: [Entry] = []
        if let directory = opendir(folder) {
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name != "." && name != ".." {
                    entries.append(Entry(name: name, type: entry.pointee.d_type))
                }
            }
            closedir(directory)
        }
        return AnyIterator(entries.makeIterator())
    }
}
