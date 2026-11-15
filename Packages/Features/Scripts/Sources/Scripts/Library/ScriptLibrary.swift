import Foundation
import Kit

/// A file found in a script folder, with the start of its text, where the metadata lives.
nonisolated struct ScriptFile: Hashable, Sendable {
    var url: URL
    /// The first ``ScriptLibrary/headerLength`` bytes as UTF-8, with invalid bytes replaced.
    var header: String
}

/// What one script folder holds.
nonisolated struct FolderListing: Hashable, Sendable {
    var folder: URL
    /// False when the folder could not be read, for example because it does not exist.
    var exists: Bool
    var files: [ScriptFile]
}

/// Reads and writes script folders. Kit has no file service, so the feature owns this one: the
/// live implementation uses the file system, and the isolated one keeps synthetic scripts in
/// memory and touches nothing.
nonisolated protocol ScriptLibrary: Sendable {
    /// The files directly inside each folder, sorted by name. Hidden files, folders, files whose
    /// name contains `.template.` and files that look binary are left out.
    @concurrent func listings(of folders: [URL]) async -> [FolderListing]

    /// Writes a new script that only the user can change, and fails if the file exists.
    @concurrent func create(_ contents: String, at url: URL) async throws

    /// True when a file or folder exists at the path.
    @concurrent func exists(_ url: URL) async -> Bool

    /// Creates the folder and its parents when they are missing.
    @concurrent func makeFolder(_ url: URL) async throws
}

nonisolated extension ScriptLibrary {
    /// How much of each file is read for its header.
    static var headerLength: Int { 16 * 1024 }
    /// The most files read from one folder.
    static var maximumFiles: Int { 2000 }

    /// True for a file name the library lists.
    static func isCandidate(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.contains(".template.")
    }
}

/// Names the library for each kind of run.
nonisolated enum ScriptLibraryKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any ScriptLibrary {
        FileScriptLibrary()
    }

    static func isolated(_ context: FeatureContext) -> any ScriptLibrary {
        MemoryScriptLibrary.samples(in: ScriptsFeature.defaultFolder(context.storage))
    }
}

/// The file system. Every method runs off the main thread.
nonisolated struct FileScriptLibrary: ScriptLibrary {
    @concurrent func listings(of folders: [URL]) async -> [FolderListing] {
        folders.map(Self.listing)
    }

    @concurrent func create(_ contents: String, at url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        // Readable by everyone, writable only by the user. Scripts run through their interpreter,
        // so no executable bit is needed, but it lets the script run from a terminal too.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @concurrent func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent func makeFolder(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func listing(_ folder: URL) -> FolderListing {
        let manager = FileManager.default
        guard
            let urls = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else {
            return FolderListing(folder: folder, exists: false, files: [])
        }
        var files: [ScriptFile] = []
        let candidates = urls.filter { Self.isCandidate($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maximumFiles)
        for url in candidates {
            // Follows a symbolic link to the file it names; the link's path stays the script's path.
            let target = url.resolvingSymlinksInPath()
            guard (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                let header = Self.header(of: target)
            else { continue }
            files.append(ScriptFile(url: url.standardizedFileURL, header: header))
        }
        return FolderListing(folder: folder, exists: true, files: files)
    }

    /// The start of the file as text, or nil for a file that holds a zero byte there, which is not
    /// a script.
    private static func header(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength), !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
