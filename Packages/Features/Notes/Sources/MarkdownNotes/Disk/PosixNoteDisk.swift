import Darwin
import Foundation

/// The disk service, over POSIX calls so every rule is explicit.
///
/// - A folder is opened once per call and every file is reached from it with `openat`, `fstatat`
///   and `renameat` by a plain name, so no name can lead out of the folder.
/// - Listing and checks use `lstat` semantics: a symbolic link is reported as a link and never
///   followed, and a read opens with `O_NOFOLLOW`, so a link swapped in after the check fails.
/// - A read opens with `O_NONBLOCK` and reads only a regular file, so a pipe named like a note can
///   never hold the thread. A file whose contents are only in the cloud is not opened at all.
/// - A write goes to a hidden file beside the target, is flushed, and is renamed into place.
///   Creating uses `RENAME_EXCL`, so two writers never take one name.
///
/// `roots` confines it to the given folders, for runs that must not touch the user's files.
nonisolated struct PosixNoteDisk: NoteDisk {
    /// The folders this service may touch, as compared paths, or nil for any folder.
    let roots: [String]?

    init(roots: [URL]?) {
        self.roots = roots?.map(Self.comparablePath)
    }

    // MARK: Listing and reading

    func list(_ folder: URL, limit: Int) throws(DiskError) -> DiskListing {
        let folderFD = try openFolder(folder)
        guard let directory = fdopendir(folderFD) else {
            let code = errno
            close(folderFD)
            throw Self.folderError(code)
        }
        defer { closedir(directory) }
        var entries: [DiskEntry] = []
        var seen = 0
        var isCut = false
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                let code = errno
                if code != 0 { throw Self.folderError(code) }
                break
            }
            guard let name = Self.name(of: item), name != ".", name != ".." else { continue }
            seen += 1
            if seen > limit {
                isCut = true
                break
            }
            guard NoteFileName.isNoteFile(name) else { continue }
            var info = stat()
            guard fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append(Self.entry(name, info))
        }
        return DiskListing(entries: entries, isCut: isCut)
    }

    func read(_ name: String, in folder: URL, limit: Int) throws(DiskError) -> DiskRead {
        try Self.check(name)
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        var before = stat()
        guard fstatat(folderFD, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.fileError(errno) }
        let listed = Self.entry(name, before)
        guard listed.kind == .regular else { throw .notRegularFile }
        guard !listed.isDataless else { throw .notDownloaded }
        let fileFD = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fileFD >= 0 else { throw Self.fileError(errno) }
        defer { close(fileFD) }
        var info = stat()
        guard fstat(fileFD, &info) == 0 else { throw Self.fileError(errno) }
        let entry = Self.entry(name, info)
        guard entry.kind == .regular else { throw .notRegularFile }
        guard !entry.isDataless else { throw .notDownloaded }
        let wanted = max(0, min(limit, Int(clamping: info.st_size)))
        var data = Data(count: wanted)
        var total = 0
        let failure = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            while total < wanted {
                let count = Darwin.read(fileFD, base + total, wanted - total)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if count == 0 { break }
                total += count
            }
            return 0
        }
        if failure != 0 { throw Self.fileError(failure) }
        data.count = total
        return DiskRead(data: data, entry: entry, isCut: info.st_size > Int64(limit))
    }

    func entry(_ name: String, in folder: URL) throws(DiskError) -> DiskEntry {
        try Self.check(name)
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        var info = stat()
        guard fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.fileError(errno) }
        return Self.entry(name, info)
    }

    // MARK: Writing

    func write(_ data: Data, named name: String, in folder: URL, mode: WriteMode, modified: Date) throws(DiskError) {
        try Self.check(name)
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        var replacedMode: mode_t?
        if case .replace(let expected) = mode {
            var current = stat()
            if fstatat(folderFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 {
                let entry = Self.entry(name, current)
                guard entry.kind == .regular else { throw .notRegularFile }
                if let expected, entry.version != expected { throw .changedElsewhere }
                replacedMode = current.st_mode & 0o7777
            } else if errno != ENOENT {
                throw Self.fileError(errno)
            } else if expected != nil {
                throw .changedElsewhere
            }
        }
        let temporary = ".notes-" + UUID().uuidString + ".tmp"
        let fileFD = openat(folderFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fileFD >= 0 else { throw Self.folderError(errno) }
        var isPlaced = false
        defer { if !isPlaced { unlinkat(folderFD, temporary, 0) } }
        // A replaced note keeps its permissions, ACL and extended attributes, such as Finder tags,
        // so a note the user made private stays private. File flags such as Locked are not copied:
        // a locked note refuses the rename instead.
        if let replacedMode {
            _ = fchmod(fileFD, replacedMode)
            Self.copyMetadata(of: name, to: fileFD, in: folderFD)
        }
        let failure = Self.writeAll(data, to: fileFD)
        if failure == 0 {
            var times = [Self.timespec(modified), Self.timespec(modified)]
            _ = futimens(fileFD, &times)
            _ = fsync(fileFD)
        }
        close(fileFD)
        if failure != 0 { throw Self.fileError(failure) }
        switch mode {
        case .create:
            try Self.placeNew(temporary, as: name, in: folderFD)
        case .replace:
            guard renameat(folderFD, temporary, folderFD, name) == 0 else { throw Self.fileError(errno) }
        }
        isPlaced = true
    }

    func move(_ name: String, to newName: String, in folder: URL) throws(DiskError) {
        try Self.check(name)
        try Self.check(newName)
        guard name != newName else { return }
        let folderFD = try openFolder(folder)
        defer { close(folderFD) }
        var info = stat()
        guard fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.fileError(errno) }
        guard Self.entry(name, info).kind == .regular else { throw .notRegularFile }
        var other = stat()
        let otherExists = fstatat(folderFD, newName, &other, AT_SYMLINK_NOFOLLOW) == 0
        if NoteFileName.comparable(name) == NoteFileName.comparable(newName) {
            // Only the case or composition changes. On a volume that ignores case both names are
            // one file; on one that does not, a different file must not be replaced.
            guard !otherExists || other.st_ino == info.st_ino else { throw .nameTaken }
            guard renameat(folderFD, name, folderFD, newName) == 0 else { throw Self.fileError(errno) }
            return
        }
        if renameatx_np(folderFD, name, folderFD, newName, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw Self.fileError(code) }
        // A volume without exclusive renames: check, then rename.
        guard !otherExists else { throw .nameTaken }
        guard renameat(folderFD, name, folderFD, newName) == 0 else { throw Self.fileError(errno) }
    }

    func prepare(_ folder: URL) throws(DiskError) {
        let path = try checkFolder(folder)
        do {
            try FileManager.default.createDirectory(
                at: URL(filePath: path, directoryHint: .isDirectory), withIntermediateDirectories: true)
        } catch {
            throw .system((error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO)
        }
    }

    // MARK: Helpers

    /// Opens the folder after checking it is one this service may touch.
    private func openFolder(_ folder: URL) throws(DiskError) -> Int32 {
        let path = try checkFolder(folder)
        let folderFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folderFD >= 0 else { throw Self.folderError(errno) }
        return folderFD
    }

    /// The folder's path, when it is absolute and inside the roots.
    private func checkFolder(_ folder: URL) throws(DiskError) -> String {
        let path = Self.comparablePath(folder)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw .badName }
        if let roots, !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { throw .outsideRun }
        return path
    }

    /// Refuses a name that is not one plain path component.
    private static func check(_ name: String) throws(DiskError) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
            name.utf8.count <= 255
        else { throw .badName }
    }

    /// Moves the written file to a name nobody holds.
    private static func placeNew(_ temporary: String, as name: String, in folderFD: Int32) throws(DiskError) {
        if renameatx_np(folderFD, temporary, folderFD, name, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw fileError(code) }
        // A volume without exclusive renames, such as some network shares: a hard link fails when
        // the name exists. Without hard links, reserve the name with an exclusive create first.
        if linkat(folderFD, temporary, folderFD, name, 0) == 0 {
            unlinkat(folderFD, temporary, 0)
            return
        }
        guard errno != EEXIST else { throw .nameTaken }
        let reserved = openat(folderFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard reserved >= 0 else { throw fileError(errno) }
        close(reserved)
        guard renameat(folderFD, temporary, folderFD, name) == 0 else {
            let code = errno
            unlinkat(folderFD, name, 0)
            throw fileError(code)
        }
    }

    /// Copies a note's metadata to the file that replaces it. Best effort: a note whose metadata
    /// cannot be read is still saved.
    private static func copyMetadata(of name: String, to fileFD: Int32, in folderFD: Int32) {
        let sourceFD = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { return }
        defer { close(sourceFD) }
        _ = fcopyfile(sourceFD, fileFD, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
    }

    /// Writes every byte, or returns the `errno` that stopped it.
    private static func writeAll(_ data: Data, to fileFD: Int32) -> Int32 {
        data.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fileFD, base + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += count
            }
            return 0
        }
    }

    static func entry(_ name: String, _ info: stat) -> DiskEntry {
        let kind: DiskEntry.Kind =
            switch info.st_mode & S_IFMT {
            case S_IFREG: .regular
            case S_IFLNK: .link
            case S_IFDIR: .folder
            default: .other
            }
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        return DiskEntry(
            name: name, kind: kind,
            version: FileVersion(
                inode: UInt64(info.st_ino), size: Int64(info.st_size),
                modifiedNanoseconds: seconds &* 1_000_000_000 &+ nanoseconds),
            modified: Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1e9),
            isDataless: info.st_flags & UInt32(SF_DATALESS) != 0)
    }

    /// The name of a directory entry, or nil when it is not UTF-8, which no note can be.
    private static func name(of item: UnsafeMutablePointer<dirent>) -> String? {
        let length = Int(item.pointee.d_namlen)
        return withUnsafeBytes(of: &item.pointee.d_name) { raw in
            String(validating: raw.prefix(length), as: UTF8.self)
        }
    }

    private static func timespec(_ date: Date) -> Darwin.timespec {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let nanoseconds = (date.timeIntervalSince1970 - seconds) * 1e9
        return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
    }

    static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func folderError(_ code: Int32) -> DiskError {
        switch code {
        case ENOENT: .folderMissing
        case ENOTDIR: .notAFolder
        case EACCES, EPERM: .accessRefused
        default: .system(code)
        }
    }

    static func fileError(_ code: Int32) -> DiskError {
        switch code {
        case ENOENT: .missing
        case ELOOP, EISDIR, ENOTDIR, EFTYPE: .notRegularFile
        case EACCES, EPERM: .accessRefused
        case EEXIST: .nameTaken
        default: .system(code)
        }
    }
}
