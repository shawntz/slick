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

    /// Makes the data folder.
    func create() throws {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    /// Deletes the folder when this run made it.
    func removeIfTemporary() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: dataRoot)
    }
}
