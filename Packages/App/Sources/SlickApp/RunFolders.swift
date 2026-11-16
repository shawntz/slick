import Foundation
import Kit
import Platform

/// The data folder one run uses.
///
/// The live launcher uses `--data-dir`, the data folder variable, or Application Support. Every
/// other mode uses `--data-dir` or the variable when given, and otherwise a fresh temporary folder
/// that is deleted when the run ends, so a selftest, bench or scenario never sees the user's data.
nonisolated struct RunFolders: Equatable, Sendable {
    let dataRoot: URL
    /// True for a folder this run made and deletes.
    let isTemporary: Bool

    static func resolve(_ options: LaunchOptions, currentDirectory: String) -> RunFolders {
        let override = options.dataDirectory.map {
            LaunchOptions.fileURL($0, currentDirectory: currentDirectory).path
        }
        if options.mode.environment == .live {
            return RunFolders(dataRoot: PlatformStorage.defaultDataRoot(override: override), isTemporary: false)
        }
        if let override {
            return RunFolders(dataRoot: URL(filePath: override, directoryHint: .isDirectory), isTemporary: false)
        }
        let name = "\(Brand.dataDirectoryName)-\(options.mode.environment.rawValue)-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        return RunFolders(dataRoot: folder, isTemporary: true)
    }

    /// The data folder's mode: only this account may read it, write it or look inside. It holds
    /// clipboard history, chats and what the launcher learned, and `--data-dir` can put it in a
    /// place other accounts can reach.
    static let mode: Int = 0o700

    /// Makes the data folder with ``mode``, and takes group and other access away from a folder
    /// that is already there, such as a custom data folder made by hand. Folders it has to make on
    /// the way get the same mode. A link to a folder changes the folder it points to.
    func create() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.mode])
        try Self.restrict(dataRoot)
    }

    /// Clears the group and other bits of a folder's mode, if any are set.
    static func restrict(_ folder: URL) throws {
        let path = folder.resolvingSymlinksInPath().path
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: path)
        guard let current = (attributes[.posixPermissions] as? NSNumber)?.intValue else { return }
        let tightened = current & ~0o077
        guard tightened != current else { return }
        try manager.setAttributes([.posixPermissions: tightened], ofItemAtPath: path)
    }

    /// Deletes the folder when this run made it.
    func removeIfTemporary() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: dataRoot)
    }
}
