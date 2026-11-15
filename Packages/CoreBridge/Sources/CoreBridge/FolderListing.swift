import SlickCoreC

/// One child of a folder listed straight from disk.
public struct FolderItem: Hashable, Sendable {
    /// The name, decoded as UTF-8 with invalid bytes replaced.
    public let name: String
    public let flags: FileEntryFlags
    /// Modification time, Unix seconds.
    public let modified: UInt32
    /// Size in bytes. Nil for a folder.
    public let size: UInt64?
}

/// A folder listed from disk with the index's rules applied.
public struct FolderListing: Hashable, Sendable {
    /// Why a folder could not be listed.
    public enum Problem: UInt8, Hashable, Sendable {
        /// The folder does not exist.
        case missing = 1
        /// The path names a file, or a symbolic link, which is never followed.
        case notAFolder = 2
        /// Reading the folder was not allowed.
        case denied = 3
        /// The folder could not be read for another reason.
        case failed = 4
    }

    /// The children the rules keep, sorted by name. Empty when there is a problem.
    public let items: [FolderItem]
    /// False when reading stopped partway, so some children may be missing.
    public let complete: Bool
    /// Why the folder could not be listed, or nil when it was.
    public let problem: Problem?
}

extension FileIndex {
    /// Lists the folder at the absolute `path` from disk, sorted by name, with the rules of
    /// `rules` applied; its roots are not used. For browsing a folder the index does not hold.
    ///
    /// Reads the disk, so call it off the main thread. Reading a folder macOS guards, such as
    /// Desktop or Downloads, can raise a permission prompt: list only folders the user chose to
    /// browse. Throws only for a path that is empty, relative or holds a NUL character.
    public static func listFolder(_ path: String, rules: FileIndexConfiguration) throws(CoreError) -> FolderListing {
        try RustCore.checkABI()
        var path = path
        var info = SlickFilesListInfo()
        var items = [SlickFilesListItem](repeating: SlickFilesListItem(), count: 64)
        var names = [UInt8](repeating: 0, count: 4096)
        // A folder can grow between the call that measures it and the call that copies it.
        for _ in 0..<4 {
            let status = path.withUTF8 { p in
                rules.withRaw { config, strings, count in
                    items.withUnsafeMutableBufferPointer { i in
                        names.withUnsafeMutableBufferPointer { n in
                            slick_files_list_folder(
                                p.baseAddress, p.count, config, strings, count, i.baseAddress, i.count, n.baseAddress,
                                n.count, &info)
                        }
                    }
                }
            }
            if status == SLICK_STATUS_BUFFER_TOO_SMALL.rawValue {
                let needItems = Int(clamping: info.items)
                let needBytes = Int(clamping: info.name_bytes)
                items = [SlickFilesListItem](repeating: SlickFilesListItem(), count: needItems + needItems / 8 + 8)
                names = [UInt8](repeating: 0, count: needBytes + needBytes / 8 + 256)
                continue
            }
            if status == SLICK_STATUS_IO.rawValue {
                return FolderListing(items: [], complete: false, problem: FolderListing.Problem(rawValue: info.problem))
            }
            let count = Int(try CoreError.check(status))
            let listed = items[..<count].map { item in
                let start = Int(item.name_start)
                let name = String(decoding: names[start..<start + Int(item.name_len)], as: UTF8.self)
                return FolderItem(
                    name: name, flags: FileEntryFlags(rawValue: item.flags), modified: item.mtime,
                    size: item.size == UInt64.max ? nil : item.size)
            }
            return FolderListing(items: listed, complete: info.complete == 1, problem: nil)
        }
        return FolderListing(items: [], complete: false, problem: .failed)
    }
}
