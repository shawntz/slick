import Foundation
import Kit

/// A folder the feature reads scripts from.
nonisolated struct ScriptFolder: Hashable, Sendable {
    var url: URL
    /// The folder in the feature's storage. It is always on.
    var isDefault: Bool
    /// Whether its scripts may run. A folder the user adds stays off until they turn it on.
    var isEnabled: Bool

    /// The folder's path as settings store it.
    var path: String { ScriptPath.key(url) }

    var displayName: String {
        isDefault ? Strings.defaultFolderName : url.lastPathComponent
    }
}

/// One file with metadata in a script folder: a command when it has no errors and its folder is
/// on, and an entry in Manage Script Commands either way.
nonisolated struct ScriptEntry: Hashable, Sendable {
    var url: URL
    var folder: ScriptFolder
    /// Stable while the file keeps its path, so aliases, hotkeys and learning survive a relaunch.
    var commandID: String
    /// The header's title, or the file name when the header has none.
    var title: String
    var problems: [ScriptProblem]
    /// Nil when the header or the first line has an error.
    var script: Script?

    /// True when the script is a command now.
    var isRunnable: Bool { script != nil && folder.isEnabled }
    var hasErrors: Bool { problems.contains { $0.severity == .error } }
    var hasWarnings: Bool { problems.contains { $0.severity == .warning } }
}

/// What a folder scan found.
nonisolated struct FolderState: Hashable, Sendable {
    var folder: ScriptFolder
    /// False when the folder could not be read.
    var exists: Bool
}

/// Every script in every folder, from one scan.
nonisolated struct ScriptCatalog: Hashable, Sendable {
    var folders: [FolderState] = []
    var entries: [ScriptEntry] = []

    /// The scripts that are commands now, in folder order, then by file name.
    var runnable: [Script] {
        entries.compactMap { $0.isRunnable ? $0.script : nil }
    }

    /// The command ID a script file gets: a readable slug of its name and a hash of its full path.
    /// The path is hashed in precomposed form, so a file system that hands back decomposed accents
    /// gives the same ID.
    static func commandID(for url: URL) -> String {
        let path = ScriptPath.key(url).precomposedStringWithCanonicalMapping
        return Command.stableID("script", name: url.deletingPathExtension().lastPathComponent, uniqueKey: path)
    }

    /// Parses every file's header off the main thread.
    @concurrent static func build(_ listings: [FolderListing], folders: [ScriptFolder]) async -> ScriptCatalog {
        make(listings, folders: folders)
    }

    /// Parses every file's header. Files with no metadata lines are not scripts and are skipped.
    static func make(_ listings: [FolderListing], folders: [ScriptFolder]) -> ScriptCatalog {
        var catalog = ScriptCatalog()
        var seenIDs = Set<String>()
        for (folder, listing) in zip(folders, listings) {
            catalog.folders.append(FolderState(folder: folder, exists: listing.exists))
            for file in listing.files {
                let parsed = HeaderParser.parse(file.header)
                guard parsed.isScript else { continue }
                var problems = parsed.problems
                let interpreter: Interpreter?
                switch Interpreter.resolve(header: file.header, fileExtension: file.url.pathExtension) {
                case .success(let found):
                    interpreter = found
                case .failure(let problem):
                    interpreter = nil
                    problems.insert(problem, at: 0)
                }
                let commandID = commandID(for: file.url)
                if !seenIDs.insert(commandID).inserted {
                    problems.insert(.error(Strings.Problem.duplicateID), at: 0)
                }
                let hasErrors = problems.contains { $0.severity == .error }
                var script: Script?
                if !hasErrors, let metadata = parsed.metadata, let interpreter {
                    script = Script(
                        url: file.url, folder: folder.url, commandID: commandID, metadata: metadata,
                        interpreter: interpreter)
                }
                let title = parsed.metadata?.title ?? HeaderParser.title(in: file.header) ?? file.url.lastPathComponent
                catalog.entries.append(
                    ScriptEntry(
                        url: file.url, folder: folder, commandID: commandID, title: title, problems: problems,
                        script: script))
            }
        }
        return catalog
    }
}

nonisolated extension HeaderParser {
    /// The first title line's value, for naming a script whose header has an error.
    static func title(in header: String) -> String? {
        lines(in: header).first { $0.key == "title" && !$0.value.isEmpty }?.value
    }
}
