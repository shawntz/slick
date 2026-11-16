import CoreBridge
import Darwin
import Foundation

/// Mounted volumes by kind, as absolute paths.
nonisolated struct MountedVolumes: Hashable, Sendable {
    var removable: [String] = []
    var network: [String] = []
}

/// Everything that decides what the index holds.
nonisolated struct ScopeInput: Hashable, Sendable {
    /// The home folder, as a real path without a trailing "/".
    var home: String
    var states: [ProtectedPlace: PlaceState]
    var extraFolders: [String] = []
    var excludedFolders: [String] = []
    var excludedNames: [String] = []
    var includesHidden = false
    var volumes = MountedVolumes()
}

/// What to index, what to watch and what never to read, worked out from a ``ScopeInput``. Pure: it
/// reads nothing, so tests check the rules directly.
///
/// The home folder is always a root, without its Library folder, which the recommended rules skip.
/// Desktop, Documents and Downloads join only when their place is searched; until then they are
/// skipped paths, so the walker never opens them and events below them are dropped. iCloud Drive
/// lives in the skipped Library folder. While it is searched its folder is a root of its own, which
/// the index keeps because the home folder's walk never enters it, so nothing else in Library is
/// listed. Volumes are roots of their own when their kind is searched. A folder the user added
/// that lies inside a place not searched is left out until the place is searched, and one inside
/// Library is left out, because Library holds other apps' data.
nonisolated struct ScopePlan: Hashable, Sendable {
    let home: String
    /// The roots, home first.
    let roots: [String]
    /// Folders never read and whose events are dropped: protected places not searched and the
    /// folders the user excluded.
    let blocked: [String]
    /// The folders that stand for each searched protected place, to tell a read error.
    let placeFolders: [ProtectedPlace: [String]]
    /// Searched place folders that must be in the index after a walk. One that is not, such as an
    /// iCloud Drive folder that could not be listed, counts as not readable.
    let expected: Set<String>
    /// Wildcard patterns that hide matching names from results.
    let patterns: NamePatterns
    let configuration: FileIndexConfiguration

    init(_ input: ScopeInput) {
        let home = Paths.normalized(input.home, home: nil) ?? "/"
        let library = home + "/Library"
        var roots = [home]
        var blocked: [String] = []
        var skipPaths: [String] = []
        var placeFolders: [ProtectedPlace: [String]] = [:]
        var expected: Set<String> = []
        for place in ProtectedPlace.folders {
            guard let folder = place.folder(home: home) else { continue }
            if input.states[place]?.isSearched == true {
                placeFolders[place] = [folder]
                if place == .iCloudDrive {
                    roots.append(folder)
                    expected.insert(folder)
                }
            } else {
                blocked.append(folder)
                if place != .iCloudDrive { skipPaths.append(folder) }
            }
        }
        for (place, volumes) in [
            (ProtectedPlace.removableVolumes, input.volumes.removable), (.networkVolumes, input.volumes.network),
        ] {
            let folders = volumes.compactMap { Paths.normalized($0, home: nil) }.filter { $0 != "/" }
            if input.states[place]?.isSearched == true {
                placeFolders[place] = folders
                expected.formUnion(folders)
                roots += folders
            } else {
                blocked += folders
            }
        }
        let excluded = input.excludedFolders.compactMap { Paths.normalized($0, home: home) }.filter { $0 != "/" }
        blocked += excluded
        skipPaths += excluded
        for folder in input.extraFolders.compactMap({ Paths.normalized($0, home: home) })
        where !blocked.contains(where: { Paths.isInside(folder, $0) }) && !Paths.isInside(folder, library)
            && !roots.contains(folder)
        {
            roots.append(folder)
        }
        let names = NamePatterns(input.excludedNames)
        self.home = home
        self.roots = roots
        self.blocked = blocked
        self.placeFolders = placeFolders
        self.expected = expected
        self.patterns = names
        // With the home folder named, the recommended rules skip its Library. A root the home
        // folder's walk never enters, such as iCloud Drive's folder or an added folder behind a
        // skipped name, is kept as a root of its own.
        configuration = FileIndexConfiguration(
            roots: roots, home: home, useRecommendedRules: true, includeHidden: input.includesHidden,
            oneFileSystem: true, skipNames: names.plainNames, skipPaths: skipPaths, keepsRootsInSkippedFolders: true)
    }

    /// True when `path` lies inside a root and outside every blocked folder: the index may read it,
    /// and its details and preview may be shown. In the home folder's Library only iCloud Drive is
    /// allowed, and only while it is searched, as its own root.
    func allows(_ path: String) -> Bool {
        guard let root = roots.filter({ Paths.isInside(path, $0) }).max(by: { $0.utf8.count < $1.utf8.count })
        else { return false }
        if blocked.contains(where: { Paths.isInside(path, $0) }) { return false }
        guard root == home, Paths.isInside(path, home + "/Library") else { return true }
        return placeFolders[.iCloudDrive]?.contains { Paths.isInside(path, $0) } == true
    }

    /// True when `path` is one of the roots. An event that names a root itself means FSEvents could
    /// not say what changed below it, so the whole root is listed again.
    func isRoot(_ path: String) -> Bool {
        roots.contains(path)
    }
}

/// Excluded names: plain names the walker skips wherever they appear, and wildcard patterns that
/// hide matching names from results.
nonisolated struct NamePatterns: Hashable, Sendable {
    /// Names without wildcards, compared without case by the walker.
    let plainNames: [String]
    /// Patterns with `*`, `?` or `[`, matched against names without case.
    let wildcards: [String]

    init(_ entries: [String]) {
        var plain: [String] = []
        var wild: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0") else { continue }
            if trimmed.contains(where: { "*?[".contains($0) }) {
                if !wild.contains(trimmed) { wild.append(trimmed) }
            } else if !plain.contains(trimmed) {
                plain.append(trimmed)
            }
        }
        plainNames = plain
        wildcards = wild
    }

    /// True when a wildcard pattern matches `name`.
    func hides(_ name: String) -> Bool {
        guard !wildcards.isEmpty else { return false }
        return wildcards.contains { pattern in fnmatch(pattern, name, FNM_CASEFOLD | FNM_PERIOD) == 0 }
    }
}

/// Path helpers that read nothing from the disk.
nonisolated enum Paths {
    /// An absolute path without "." or ".." parts, repeated or trailing slashes. A leading "~" is
    /// expanded when `home` is given. Nil for a relative or empty path.
    static func normalized(_ path: String, home: String?) -> String? {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let home, text == "~" || text.hasPrefix("~/") {
            text = home + text.dropFirst()
        }
        guard text.hasPrefix("/"), !text.contains("\0") else { return nil }
        var parts: [Substring] = []
        for part in text.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// True when `path` is `folder` or lies below it. Compares bytes, as the index does.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let slash = UInt8(ascii: "/")
        let bytes = path.utf8
        if folder == "/" { return bytes.first == slash }
        guard bytes.starts(with: folder.utf8) else { return false }
        let length = folder.utf8.count
        return bytes.count == length || bytes[bytes.index(bytes.startIndex, offsetBy: length)] == slash
    }

    /// The path as people read it: "~" for the home folder and paths below it.
    static func display(_ path: String, home: String) -> String {
        guard home != "/", isInside(path, home) else { return path }
        return "~" + String(decoding: path.utf8.dropFirst(home.utf8.count), as: UTF8.self)
    }

    /// The last part of a path, or the path itself for "/".
    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), path != "/" else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The folder that holds `path`.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
