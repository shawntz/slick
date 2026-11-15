import Foundation
import Kit
import Synchronization

/// Script folders in memory, for scenarios, self-tests, benchmarks and tests. It reads and writes
/// nothing on disk. Scenarios start with a few synthetic scripts in the default folder.
nonisolated final class MemoryScriptLibrary: ScriptLibrary {
    /// Each file's text by path.
    private let files: Mutex<[String: String]>
    /// The paths of the folders that exist.
    private let folders: Mutex<Set<String>>

    /// - Parameter files: Each script's full text by location. Their folders exist.
    init(files: [URL: String] = [:]) {
        let byPath = Dictionary(
            files.map { (ScriptPath.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.files = Mutex(byPath)
        self.folders = Mutex(Set(files.keys.map { ScriptPath.key($0.deletingLastPathComponent()) }))
    }

    /// A library with a compact, an inline and a list script in the folder.
    static func samples(in folder: URL) -> MemoryScriptLibrary {
        let prefix = HeaderParser.ownPrefix
        func script(_ mode: String, title: String, extra: [String] = [], body: String) -> String {
            (["#!/bin/bash", "# \(prefix)schemaVersion 1", "# \(prefix)title \(title)", "# \(prefix)mode \(mode)"]
                + extra.map { "# \(prefix)\($0)" } + ["", body]).joined(separator: "\n")
        }
        return MemoryScriptLibrary(files: [
            folder.appending(path: "say-hello.sh"): script(
                "compact", title: "Say Hello", extra: ["icon 👋"], body: "echo \"Hello World!\""),
            folder.appending(path: "uptime.sh"): script(
                "inline", title: "Uptime", extra: ["refreshTime 1m"], body: "uptime"),
            folder.appending(path: "search-colors.sh"): script(
                "list", title: "Search Colors",
                body: ##"echo '{"items": [{"uid": "red", "title": "Red", "arg": "#FF0000"}]}'"##),
        ])
    }

    /// The text of the file at a location, for tests.
    func contents(of url: URL) -> String? {
        files.withLock { $0[ScriptPath.key(url)] }
    }

    /// Adds or replaces a file, as a person editing a script folder would.
    func write(_ contents: String, at url: URL) {
        files.withLock { $0[ScriptPath.key(url)] = contents }
        _ = folders.withLock { $0.insert(ScriptPath.key(url.deletingLastPathComponent())) }
    }

    /// Removes a file.
    func remove(_ url: URL) {
        _ = files.withLock { $0.removeValue(forKey: ScriptPath.key(url)) }
    }

    @concurrent func listings(of folders: [URL]) async -> [FolderListing] {
        let (files, existing) = (self.files.withLock { $0 }, self.folders.withLock { $0 })
        return folders.map { folder in
            let key = ScriptPath.key(folder)
            let inside =
                files
                .filter { path, text in
                    let url = URL(filePath: path)
                    return ScriptPath.key(url.deletingLastPathComponent()) == key
                        && Self.isCandidate(url.lastPathComponent) && !text.utf8.contains(0)
                }
                .sorted { URL(filePath: $0.key).lastPathComponent < URL(filePath: $1.key).lastPathComponent }
                .prefix(Self.maximumFiles)
                .map { path, text in
                    ScriptFile(
                        url: URL(filePath: path),
                        header: String(decoding: Array(text.utf8.prefix(Self.headerLength)), as: UTF8.self))
                }
            return FolderListing(folder: folder, exists: existing.contains(key), files: Array(inside))
        }
    }

    @concurrent func create(_ contents: String, at url: URL) async throws {
        let key = ScriptPath.key(url)
        try files.withLock { files in
            guard files[key] == nil else { throw CocoaError(.fileWriteFileExists) }
            files[key] = contents
        }
        _ = folders.withLock { $0.insert(ScriptPath.key(url.deletingLastPathComponent())) }
    }

    @concurrent func exists(_ url: URL) async -> Bool {
        let key = ScriptPath.key(url)
        return files.withLock { $0[key] != nil } || folders.withLock { $0.contains(key) }
    }

    @concurrent func makeFolder(_ url: URL) async throws {
        _ = folders.withLock { $0.insert(ScriptPath.key(url)) }
    }
}
