import Foundation
import os

/// Writes root search's small JSON files: atomically, in a folder only the owner can open, with
/// owner-only permissions on the file.
nonisolated enum JSONFiles {
    /// Writes `data` to `url` atomically. Logs and returns false when that fails.
    @discardableResult
    static func write(_ data: Data, to url: URL, log: Logger) -> Bool {
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
            return true
        } catch {
            log.error("root search could not write \(url.lastPathComponent, privacy: .public): \(error)")
            return false
        }
    }

    /// The bytes every regular file in a folder takes, without descending into subfolders, plus the
    /// given files. Missing files count 0. Reads file attributes, so never call it on the main thread.
    static func bytes(inFolder folder: URL?, files: [URL?]) -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0
        func size(_ url: URL) -> Int64 {
            let attributes = try? manager.attributesOfItem(atPath: url.path(percentEncoded: false))
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { return 0 }
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        if let folder, let names = try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) {
            for name in names {
                total += size(folder.appending(path: name, directoryHint: .notDirectory))
            }
        }
        for case let file? in files {
            total += size(file)
        }
        return total
    }
}
