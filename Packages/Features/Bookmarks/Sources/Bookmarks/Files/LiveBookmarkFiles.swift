import Foundation
import Kit

/// The file service in the app: it reads the browsers' bookmark files under the user's home folder.
///
/// What it touches, and nothing else:
///
/// - It lists the folders in `Browser.dataFolder` to find profiles, and checks that each profile's
///   bookmark file exists. It never lists or opens Safari's folder without Full Disk Access.
/// - It reads `Bookmarks.plist` for Safari, `Bookmarks` and `AccountBookmarks` in each Chromium
///   profile, and clones `places.sqlite` and its log for Firefox into a private folder in the
///   feature's cache, which it deletes at once. It never opens Firefox's own files with SQLite.
/// - It reads no other file: not `Local State`, `profiles.ini`, history, cookies or passwords.
/// - It follows no link, and refuses a profile whose files lie outside the browser's folder.
/// - It writes only inside the feature's cache folder, and sends nothing anywhere.
///
/// The feature asks only for browsers the user switched on, so nothing here runs until then.
nonisolated final class LiveBookmarkFiles: BookmarkFileService {
    private let home: URL
    private let scratch: URL
    private let permissions: PermissionReader

    /// Does no I/O.
    init(home: URL, scratch: URL, permissions: PermissionReader) {
        self.home = home
        self.scratch = scratch
        self.permissions = permissions
    }

    func watchFolder(for browser: Browser) -> URL {
        home.appending(path: browser.dataFolder, directoryHint: .isDirectory)
    }

    @concurrent func profiles(of browser: Browser) async -> [BrowserProfile] {
        guard mayRead(browser) else { return [] }
        return BrowserFolders.profiles(of: browser, in: watchFolder(for: browser))
    }

    @concurrent func contents(of profile: BrowserProfile) async throws(BookmarkReadError) -> [Data] {
        guard mayRead(profile.browser) else { throw .accessDenied }
        let folder = watchFolder(for: profile.browser)
        guard profile.files.allSatisfy({ BrowserFolders.isExpected($0, browser: profile.browser, in: folder) }) else {
            throw .unreadable
        }
        switch profile.browser.format {
        case .firefoxPlaces:
            var images: [Data] = []
            for database in profile.files where BrowserFolders.isRegularFile(database) {
                images.append(try PrivateCopy.firefoxBookmarkImage(of: database, scratchRoot: scratch))
            }
            return images
        case .safariPropertyList, .chromiumJSON:
            var contents: [Data] = []
            for file in profile.files {
                if let data = try BrowserFolders.read(file) { contents.append(data) }
            }
            return contents
        }
    }

    @concurrent func stamp(of profile: BrowserProfile) async -> FileStamp {
        guard mayRead(profile.browser) else { return FileStamp() }
        let folder = watchFolder(for: profile.browser)
        let files = BrowserFolders.stampedFiles(of: profile).filter { file in
            file.path(percentEncoded: false).hasPrefix(folder.path(percentEncoded: false))
        }
        return FileStamp.of(files)
    }

    /// Safari's folder is opened only with Full Disk Access, so the system is never asked for it.
    private func mayRead(_ browser: Browser) -> Bool {
        !browser.needsFullDiskAccess || permissions.isGranted(.fullDiskAccess)
    }
}
