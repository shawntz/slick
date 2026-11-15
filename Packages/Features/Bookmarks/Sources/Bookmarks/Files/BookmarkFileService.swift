import Foundation
import Kit

/// What the feature needs from the disk: the profiles of a browser, the bytes of their bookmark
/// files, and a cheap way to tell whether those files changed. It lives in this package because no
/// other feature needs it.
///
/// Every requirement that does work is `@concurrent`, so it runs off the main thread whoever calls
/// it. The live service reads the browsers' files under the real home folder. The isolated one
/// serves synthetic bookmarks from memory and touches no file.
nonisolated protocol BookmarkFileService: Sendable {
    /// The browser's profiles that hold a bookmarks file, found by listing its folder. Reads no
    /// file's contents. Safari has one profile, and none without Full Disk Access.
    @concurrent func profiles(of browser: Browser) async -> [BrowserProfile]

    /// The bytes of each of the profile's bookmark files that exists, the main one first. For
    /// Firefox, a small database image that holds only the bookmark tables.
    @concurrent func contents(of profile: BrowserProfile) async throws(BookmarkReadError) -> [Data]

    /// When and how large the profile's files were last written, to skip reading files that did not
    /// change. Reads no file's contents.
    @concurrent func stamp(of profile: BrowserProfile) async -> FileStamp

    /// The folder to watch for the browser. It holds every profile, so a new profile is noticed too.
    func watchFolder(for browser: Browser) -> URL
}

/// The size and modification time of a profile's files. Equal stamps mean nothing changed.
nonisolated struct FileStamp: Hashable, Sendable {
    struct Part: Hashable, Sendable {
        var name: String
        var modified: Double
        var size: Int64
    }

    var parts: [Part] = []

    /// The stamp of files on disk, read with `lstat`, so a link is never followed. Missing files
    /// are left out.
    static func of(_ files: [URL]) -> FileStamp {
        FileStamp(
            parts: files.compactMap { file in
                guard
                    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
                else { return nil }
                return Part(
                    name: file.lastPathComponent,
                    modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
            })
    }
}

/// The file service for each kind of run. Scenarios, self-tests and benchmarks get synthetic
/// bookmarks, so they can never read a browser's real files.
nonisolated enum BookmarkFileServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any BookmarkFileService {
        LiveBookmarkFiles(
            home: context.storage.homeDirectory, scratch: context.storage.cacheDirectory,
            permissions: context.permissions)
    }

    static func isolated(_ context: FeatureContext) -> any BookmarkFileService {
        IsolatedBookmarkFiles.sample(home: context.storage.homeDirectory)
    }
}
