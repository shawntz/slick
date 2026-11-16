import Foundation
import Kit

/// The file work behind notes: list a folder, read a note, write one atomically, rename one.
///
/// Every call is synchronous and does real I/O, so only ``NoteStore``, an actor, calls it, never
/// the main thread. Every call takes the folder and a plain file name, never a path, and refuses a
/// name that is not one path component. Reads never follow a symbolic link, never open anything
/// but a regular file, and never wait on a pipe.
nonisolated protocol NoteDisk: Sendable {
    /// Every entry of the folder, at most `limit` of them, without following links.
    func list(_ folder: URL, limit: Int) throws(DiskError) -> DiskListing

    /// The first `limit` bytes of a regular file in the folder.
    func read(_ name: String, in folder: URL, limit: Int) throws(DiskError) -> DiskRead

    /// Facts about one entry, without following a link.
    func entry(_ name: String, in folder: URL) throws(DiskError) -> DiskEntry

    /// Writes the bytes to a new file beside the target and renames it into place, so a reader
    /// sees the old note or the new one, never half of each. The file's modification date is set
    /// to `modified`. Creating fails with ``DiskError/nameTaken`` when the name exists; replacing
    /// fails with ``DiskError/changedElsewhere`` when the file is no longer `expected`.
    func write(_ data: Data, named name: String, in folder: URL, mode: WriteMode, modified: Date) throws(DiskError)

    /// Renames a regular file. Fails with ``DiskError/nameTaken`` when another file has the new name.
    func move(_ name: String, to newName: String, in folder: URL) throws(DiskError)

    /// Creates the folder and the folders above it when they are missing. Only the default folder,
    /// which lives in the feature's own data folder, is ever created.
    func prepare(_ folder: URL) throws(DiskError)
}

/// What a write does when the name exists.
nonisolated enum WriteMode: Hashable, Sendable {
    /// Make a new file; fail when the name is taken.
    case create
    /// Replace the file, when it is still the version given. Nil replaces whatever is there.
    case replace(expected: FileVersion?)
}

/// What tells two versions of one file apart: its inode, size and modification time.
nonisolated struct FileVersion: Hashable, Sendable {
    var inode: UInt64
    var size: Int64
    var modifiedNanoseconds: Int64
}

/// One entry of a folder, as `lstat` sees it.
nonisolated struct DiskEntry: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case regular
        case link
        case folder
        /// A pipe, a socket or a device.
        case other
    }

    var name: String
    var kind: Kind
    var version: FileVersion
    var modified: Date
    /// True for a file whose contents live only in the cloud, such as in iCloud Drive. Reading it
    /// would download it.
    var isDataless: Bool
}

nonisolated struct DiskListing: Hashable, Sendable {
    var entries: [DiskEntry]
    /// True when the folder holds more entries than the limit.
    var isCut: Bool
}

nonisolated struct DiskRead: Hashable, Sendable {
    var data: Data
    /// The file as it was when read.
    var entry: DiskEntry
    /// True when the file is longer than what was read.
    var isCut: Bool
}

/// Why a disk call failed.
nonisolated enum DiskError: Error, Hashable, Sendable {
    case folderMissing
    case notAFolder
    /// macOS or the folder's permissions refused access.
    case accessRefused
    /// A scenario, a self-test or a benchmark asked for a folder outside its own temporary folders.
    case outsideRun
    /// The entry is missing.
    case missing
    /// The entry is a link, a folder, a pipe or a device.
    case notRegularFile
    /// The file's contents are only in the cloud.
    case notDownloaded
    case nameTaken
    case changedElsewhere
    /// A name that is not one plain path component.
    case badName
    /// Any other failure, by `errno`.
    case system(Int32)
}

/// Names the disk service for each kind of run.
///
/// The live service reads and writes any folder the user chose. The isolated one, for scenarios,
/// self-tests and benchmarks, does the same inside the run's own temporary folders only, so a
/// scenario that names a real folder in settings touches nothing outside its run.
nonisolated enum NoteDiskKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any NoteDisk {
        PosixNoteDisk(roots: nil)
    }

    static func isolated(_ context: FeatureContext) -> any NoteDisk {
        PosixNoteDisk(
            roots: [context.storage.dataDirectory, context.storage.cacheDirectory, context.storage.homeDirectory])
    }
}
