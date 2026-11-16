import CoreBridge
import Darwin
import Foundation
import Kit

/// Decides whether a folder the index does not hold may be listed from disk, for a typed path such
/// as "/Applications/". It reads metadata only, never a folder's contents.
///
/// A folder may be listed when it lies outside every refused folder and on an allowed device. The
/// app refuses the home folder, the folders the scope blocks, and the places that hold other
/// volumes, network mounts and other apps' temporary data, and it allows only the startup volume.
///
/// The check walks the path from "/" one part at a time and stops at the first part that is a
/// symbolic link, lies on another device, or is a refused folder under another spelling, such as
/// "/USERS/name" for the home folder. So it never looks inside a folder it refused, and never
/// touches a place macOS guards with a prompt.
nonisolated struct BrowseGuard: Hashable, Sendable {
    /// Folders never listed, with everything below them.
    var refused: [String]
    /// The devices whose folders may be listed. Nil allows every device, for tests on temporary
    /// folders.
    var devices: Set<Int32>?

    /// Folders outside the home folder that hold other volumes, network mounts or other apps' data.
    static let systemRefused = [
        "/Volumes", "/System/Volumes", "/Network", "/net", "/home", "/private/var/folders",
    ]

    /// The guard the app uses. Reads the metadata of "/" and of the startup volume's data volume.
    static func live(home: String, blocked: [String]) -> BrowseGuard {
        var devices: Set<Int32> = []
        var info = stat()
        for volume in ["/", "/System/Volumes/Data"] where lstat(volume, &info) == 0 {
            devices.insert(info.st_dev)
        }
        return BrowseGuard(refused: [home] + blocked + systemRefused, devices: devices)
    }

    /// The path to list for a folder the user typed, or nil when it may not be listed.
    /// "/tmp", "/var" and "/etc" are read as "/private/tmp", "/private/var" and "/private/etc",
    /// because the system links them there.
    func listablePath(_ folder: String) -> String? {
        guard let typed = Paths.normalized(folder, home: nil) else { return nil }
        let path = Self.systemSpelling(typed)
        let refused = refused.compactMap { Paths.normalized($0, home: nil) }.map(Self.systemSpelling)
        if refused.contains(where: { Self.isInsideIgnoringCase(path, $0) }) { return nil }
        // The identities of the refused folders outside the home folder's own subfolders and outside
        // other volumes, so another spelling of one is refused too. Reading a folder's own metadata
        // never prompts; only reading inside a guarded folder does.
        var identities: Set<Identity> = []
        for folder in refused where !refused.contains(where: { $0 != folder && Self.isInside(folder, $0) }) {
            var info = stat()
            if stat(folder, &info) == 0 { identities.insert(Identity(info)) }
        }
        var info = stat()
        guard lstat("/", &info) == 0, devices?.contains(info.st_dev) ?? true else { return nil }
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix += "/" + part
            guard lstat(prefix, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK { return nil }
            if let devices, !devices.contains(info.st_dev) { return nil }
            if identities.contains(Identity(info)) { return nil }
        }
        return info.st_mode & S_IFMT == S_IFDIR ? path : nil
    }

    /// A file's device and inode, which name it whatever the spelling.
    private struct Identity: Hashable {
        var device: Int32
        var inode: UInt64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    static func systemSpelling(_ path: String) -> String {
        for linked in ["/tmp", "/var", "/etc"] where Paths.isInside(path, linked) {
            return "/private" + path
        }
        return path
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        Paths.isInside(path, folder)
    }

    /// Like ``Paths/isInside(_:_:)``, without case, because the startup volume ignores it.
    static func isInsideIgnoringCase(_ path: String, _ folder: String) -> Bool {
        Paths.isInside(path.lowercased(), folder.lowercased())
    }
}

/// Rows for a folder listed from disk, for a query that browses a folder the index does not hold.
nonisolated enum FolderBrowser {
    /// The folder and the filter of a query that browses, read as the index reads it: "~" stands
    /// for the home folder, and the text after the last "/" filters the folder before it.
    static func split(_ query: String, home: String) -> (folder: String, filter: String)? {
        var text = query.trimmingCharacters(in: .whitespaces)
        guard SearchLane.isBrowse(text) else { return nil }
        if text.hasPrefix("~") {
            let rest = text.dropFirst()
            text = home + (rest.hasPrefix("/") ? "" : "/") + rest
        }
        guard let slash = text.lastIndex(of: "/") else { return nil }
        let folder = String(text[..<slash])
        guard let normalized = Paths.normalized(folder.isEmpty ? "/" : folder, home: nil) else { return nil }
        return (normalized, String(text[text.index(after: slash)...]))
    }

    /// Lists the folder a browsing query names when the scope's guard allows it, and makes its rows.
    /// Nil when the query browses nothing, or the folder may not or cannot be listed.
    @concurrent static func rows(
        for request: SearchRequest, scope: ScopePlan, fileSystem: any FileSystem
    ) async -> [Row]? {
        guard let (folder, filter) = split(request.query, home: scope.home),
            let listing = await fileSystem.listFolder(folder, scope: scope), listing.problem == nil
        else { return nil }
        return rows(listing, folder: folder, filter: filter, request: request)
    }

    /// The rows of one listing: names that hold the filter, without case or accents, those that
    /// start with it first, each in the listing's order. Hidden names show when the request allows
    /// them or the filter starts with a dot, as in the index.
    static func rows(_ listing: FolderListing, folder: String, filter: String, request: SearchRequest) -> [Row] {
        let showsHidden = request.includesHidden || filter.hasPrefix(".")
        var style = request.style
        style.absoluteCompletions = request.query.utf8.first == UInt8(ascii: "/")
        var starts: [Row] = []
        var others: [Row] = []
        for item in listing.items where starts.count < request.limit {
            if item.flags.contains(.hidden) && !showsHidden { continue }
            if request.patterns.hides(item.name) { continue }
            if let kind = request.kind, FileKind.of(name: item.name, flags: item.flags) != kind { continue }
            var highlights: [Range<Int>] = []
            var isStart = true
            if !filter.isEmpty {
                let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
                guard let found = item.name.range(of: filter, options: options) else { continue }
                isStart = item.name.range(of: filter, options: options.union(.anchored)) != nil
                let range = NSRange(found, in: item.name)
                highlights = [range.location..<(range.location + range.length)]
            }
            let path = folder == "/" ? "/" + item.name : folder + "/" + item.name
            let row = FileRows.row(
                path: path, flags: item.flags, modified: item.modified, highlights: highlights, style: style)
            if isStart { starts.append(row) } else { others.append(row) }
        }
        return Array((starts + others).prefix(request.limit))
    }
}
