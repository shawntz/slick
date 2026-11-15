import Foundation
import Synchronization

/// Where each browser keeps its bookmarks, and how to read them, given a browser's folder. Works on
/// any folder, so tests run it on synthetic trees; only ``LiveBookmarkFiles`` points it at the real
/// home.
nonisolated enum BrowserFolders {
    /// The bookmark files of a Chromium profile: `Bookmarks`, and `AccountBookmarks`, where newer
    /// versions may keep bookmarks saved to the signed-in account.
    static let chromiumFiles = ["Bookmarks", "AccountBookmarks"]
    static let safariFile = "Bookmarks.plist"
    static let firefoxFile = "places.sqlite"
    /// The file names whose change means a bookmark may have changed.
    static let watchedNames: Set<String> = Set(chromiumFiles + [safariFile, firefoxFile, firefoxFile + "-wal"])
    /// No browser writes a bookmarks file this large. Firefox's database holds history too, and is
    /// read through a clone, so its limit is higher.
    static let fileLimit: Int64 = 256 * 1_024 * 1_024
    static let databaseLimit: Int64 = 4 * 1_024 * 1_024 * 1_024

    /// The browser's profiles that hold a bookmarks file, in folder name order with "Default"
    /// first. Lists folders and checks that files exist; reads nothing else.
    static func profiles(of browser: Browser, in folder: URL) -> [BrowserProfile] {
        switch browser.format {
        case .safariPropertyList:
            return [BrowserProfile(browser: browser, key: "", files: [folder.appending(path: safariFile)])]
        case .chromiumJSON:
            var profiles: [BrowserProfile] = []
            // Opera keeps its one profile in the browser's own folder.
            let own = chromiumFiles.map { folder.appending(path: $0) }
            if own.contains(where: isRegularFile) {
                profiles.append(BrowserProfile(browser: browser, key: "", files: own))
            }
            for name in subfolders(of: folder) where name == "Default" || name.hasPrefix("Profile ") {
                let files = chromiumFiles.map { folder.appending(path: name).appending(path: $0) }
                if files.contains(where: isRegularFile) {
                    profiles.append(BrowserProfile(browser: browser, key: name, files: files))
                }
            }
            return profiles
        case .firefoxPlaces:
            return subfolders(of: folder).compactMap { name in
                let database = folder.appending(path: name).appending(path: firefoxFile)
                return isRegularFile(database) ? BrowserProfile(browser: browser, key: name, files: [database]) : nil
            }
        }
    }

    /// The files whose stamp says whether the profile changed: its bookmark files, and for Firefox
    /// the write-ahead log beside the database, where recent changes wait.
    static func stampedFiles(of profile: BrowserProfile) -> [URL] {
        guard profile.browser.format == .firefoxPlaces else { return profile.files }
        return profile.files.flatMap { [$0, URL(filePath: $0.path(percentEncoded: false) + "-wal")] }
    }

    /// True when the file is one the feature reads for this browser and sits inside its folder, so a
    /// profile made up elsewhere cannot point the service at another file.
    static func isExpected(_ file: URL, browser: Browser, in folder: URL) -> Bool {
        let path = file.standardizedFileURL.path(percentEncoded: false)
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), !path.contains("/../") else { return false }
        switch browser.format {
        case .safariPropertyList: return file.lastPathComponent == safariFile
        case .chromiumJSON: return chromiumFiles.contains(file.lastPathComponent)
        case .firefoxPlaces: return file.lastPathComponent == firefoxFile
        }
    }

    /// The file's bytes, or nil when it does not exist. A link is never followed: it reads as
    /// unreadable.
    static func read(_ file: URL, limit: Int64 = fileLimit) throws(BookmarkReadError) -> Data? {
        let path = file.path(percentEncoded: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            if isMissing(error) { return nil }
            throw readError(error)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw .unreadable }
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) <= limit else { throw .tooLarge }
        do {
            return try Data(contentsOf: file)
        } catch {
            if isMissing(error) { return nil }
            throw readError(error)
        }
    }

    /// True for a regular file, never for a link to one.
    static func isRegularFile(_ file: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    /// The names of the folder's subfolders, links left out, in the order people expect: "Default"
    /// first, then "Profile 2" before "Profile 10".
    private static func subfolders(of folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let path = folder.appending(path: name).path(percentEncoded: false)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return attributes?[.type] as? FileAttributeType == .typeDirectory
        }
        .sorted { left, right in
            if left == "Default" || right == "Default" { return left == "Default" && right != "Default" }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    static func readError(_ error: any Error) -> BookmarkReadError {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        for candidate in [error, underlying].compactMap(\.self) {
            if candidate.domain == NSCocoaErrorDomain && candidate.code == NSFileReadNoPermissionError {
                return .accessDenied
            }
            if candidate.domain == NSPOSIXErrorDomain && (candidate.code == Int(EPERM) || candidate.code == Int(EACCES))
            {
                return .accessDenied
            }
        }
        return .unreadable
    }
}

/// Reads Firefox's database without disturbing a running Firefox.
///
/// Firefox keeps `places.sqlite` open and writes recent changes to `places.sqlite-wal` first.
/// Opening its files with SQLite would take locks Firefox also takes. Instead the two files are
/// cloned into a private folder, the log first, and only the clone is opened. On APFS a clone
/// shares the original's blocks, so it costs little whatever the size. The folder is deleted at
/// once.
///
/// The clone holds Firefox's whole history, not only its bookmarks. A copy left behind because the
/// app quit or crashed during a read is deleted by the next read, before it makes its own.
nonisolated enum PrivateCopy {
    /// The start of each private folder's name.
    static let folderPrefix = "firefox-"

    /// One copy at a time in this process, so a read never deletes a folder another read still uses.
    private static let inUse = Mutex(())

    /// The bookmark tables of the Firefox database at `database`, read through a clone made inside
    /// `scratchRoot`.
    static func firefoxBookmarkImage(of database: URL, scratchRoot: URL) throws(BookmarkReadError) -> Data {
        try inUse.withLock { _ throws(BookmarkReadError) -> Data in
            removeLeftovers(in: scratchRoot)
            return try copyAndRead(database, scratchRoot: scratchRoot)
        }
    }

    /// Deletes private folders an earlier read left behind. Only real folders whose name starts with
    /// ``folderPrefix`` directly inside `scratchRoot`; a link is never followed or removed.
    static func removeLeftovers(in scratchRoot: URL) {
        let manager = FileManager.default
        let root = scratchRoot.path(percentEncoded: false)
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(folderPrefix) {
            // No trailing slash: with one, the system would follow a link to read the type.
            let folder = scratchRoot.appending(path: name, directoryHint: .notDirectory)
            let attributes = try? manager.attributesOfItem(atPath: folder.path(percentEncoded: false))
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
            try? manager.removeItem(at: folder)
        }
    }

    private static func copyAndRead(_ database: URL, scratchRoot: URL) throws(BookmarkReadError) -> Data {
        let folder = scratchRoot.appending(path: folderPrefix + UUID().uuidString, directoryHint: .isDirectory)
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unreadable
        }
        defer { try? manager.removeItem(at: folder) }
        // SQLite refuses a path with any link in it, and the copy is opened that way, so the
        // private folder is named by its real path, such as /private/var rather than /var.
        let copy = realPath(folder).appending(path: BrowserFolders.firefoxFile)
        let log = URL(filePath: database.path(percentEncoded: false) + "-wal")
        // The log first: if Firefox folds the log into the database between the two clones, the
        // cloned database already holds what the cloned log adds, so nothing is lost.
        if BrowserFolders.isRegularFile(log) {
            try clone(
                log, to: URL(filePath: copy.path(percentEncoded: false) + "-wal"), limit: BrowserFolders.fileLimit)
        }
        try clone(database, to: copy, limit: BrowserFolders.databaseLimit)
        return try FirefoxPlaces.bookmarkImage(ofCopyAt: copy)
    }

    /// The folder's path with every link resolved, keeping `/private` where it belongs.
    private static func realPath(_ folder: URL) -> URL {
        guard let resolved = realpath(folder.path(percentEncoded: false), nil) else { return folder }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    private static func clone(_ source: URL, to destination: URL, limit: Int64) throws(BookmarkReadError) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path(percentEncoded: false))
        } catch {
            throw BrowserFolders.readError(error)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw .unreadable }
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) <= limit else { throw .tooLarge }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw BrowserFolders.readError(error)
        }
    }
}
