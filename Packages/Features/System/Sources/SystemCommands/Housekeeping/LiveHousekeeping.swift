import AppKit
import Foundation
import Kit

/// The real Trash, disks and Finder setting. Used only when the app runs for a person.
///
/// - The Trash: `FileManager` lists and deletes the items in the user's Trash folder, and, when
///   asked, in each mounted disk's `.Trashes/<uid>` folder. macOS guards the Trash, so this needs
///   Full Disk Access; without it the listing fails and the command shows the permission card.
///   Scripting Finder would need Automation instead, and the brief prefers frameworks.
/// - Disks: `FileManager.mountedVolumeURLs` and `FileManager.unmountVolume`, without UI, so the
///   command reports failures in its own words.
/// - Hidden files: `CFPreferences` writes Finder's `AppleShowAllFiles`, then Finder is asked to quit
///   with `NSRunningApplication.terminate()` and opened again with `NSWorkspace`. Finder reads the
///   setting only when it starts.
nonisolated final class LiveHousekeeping: HousekeepingService {
    static let finderID = "com.apple.finder"
    static let finder = URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)
    private static let showAllFilesKey = "AppleShowAllFiles"
    /// Bookkeeping files Finder keeps in the Trash. They are not items the user threw away.
    private static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    init() {}

    // MARK: - Trash

    @concurrent func trashItemCount(includingVolumes: Bool) async throws -> Int {
        var count = 0
        for folder in try Self.trashFolders(includingVolumes: includingVolumes) {
            count += try Self.items(in: folder).count
        }
        return count
    }

    @concurrent func emptyTrash(includingVolumes: Bool) async throws -> TrashResult {
        var result = TrashResult(deleted: 0, failed: 0)
        for folder in try Self.trashFolders(includingVolumes: includingVolumes) {
            for item in try Self.items(in: folder) {
                if Self.delete(item) {
                    result.deleted += 1
                } else {
                    result.failed += 1
                }
            }
        }
        return result
    }

    /// The user's Trash folder, then the Trash on each other writable mounted volume that has one.
    /// Every folder is checked to be a Trash folder by name, before and after following links, so
    /// neither a wrong answer from the system nor a Trash replaced by a link can point the delete at
    /// another folder.
    private static func trashFolders(includingVolumes: Bool) throws -> [URL] {
        let manager = FileManager.default
        guard
            let home = try? manager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
            isSafeTrashFolder(home)
        else {
            throw SystemFailure.unavailable
        }
        var folders = [home]
        guard includingVolumes else { return folders }
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        for volume in manager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsRootFileSystem != true, values?.volumeIsReadOnly != true else { continue }
            guard
                let trash = try? manager.url(
                    for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false),
                isSafeTrashFolder(trash), trash.standardizedFileURL != home.standardizedFileURL,
                manager.fileExists(atPath: trash.path)
            else { continue }
            folders.append(trash)
        }
        return folders
    }

    /// A Trash folder by name, and still one once links are followed.
    static func isSafeTrashFolder(_ url: URL) -> Bool {
        isTrashFolder(url) && isTrashFolder(url.resolvingSymlinksInPath())
    }

    /// True for `~/.Trash` and for `<volume>/.Trashes/<uid>`.
    static func isTrashFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        guard path.count >= 3 else { return false }
        return path.last == ".Trash" || path[path.count - 2] == ".Trashes"
    }

    /// The items directly inside a Trash folder.
    private static func items(in folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { !ignoredNames.contains($0.lastPathComponent) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw SystemFailure.permissionMissing(.fullDiskAccess)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(truncatingIfNeeded: error.code))
        {
            throw SystemFailure.permissionMissing(.fullDiskAccess)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Deletes one item. A locked item is unlocked and tried once more. Returns false when it stays.
    ///
    /// A link is never unlocked: changing its flags could change the file it points to, which may
    /// lie outside the Trash.
    private static func delete(_ item: URL) -> Bool {
        let manager = FileManager.default
        if (try? manager.removeItem(at: item)) != nil { return true }
        let current = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isUserImmutableKey])
        guard mayUnlock(isSymbolicLink: current?.isSymbolicLink, isLocked: current?.isUserImmutable) else {
            return false
        }
        var unlocked = item
        var values = URLResourceValues()
        values.isUserImmutable = false
        guard (try? unlocked.setResourceValues(values)) != nil else { return false }
        return (try? manager.removeItem(at: item)) != nil
    }

    /// True only for an item that is known to be locked and known not to be a link.
    static func mayUnlock(isSymbolicLink: Bool?, isLocked: Bool?) -> Bool {
        isSymbolicLink == false && isLocked == true
    }

    // MARK: - Disks

    @concurrent func ejectableDisks() async throws -> [Disk] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                Self.canEject(path: url.path)
            else { return nil }
            let isLocal = values.volumeIsLocal ?? true
            let ejectable =
                values.volumeIsEjectable == true || values.volumeIsRemovable == true
                || values.volumeIsInternal == false || !isLocal
            guard ejectable else { return nil }
            return Disk(
                name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path, isNetwork: !isLocal)
        }
    }

    @concurrent func eject(_ disk: Disk, keepingOtherPartitions: Bool) async throws {
        guard Self.canEject(path: disk.path) else { throw SystemFailure.unavailable }
        var options: FileManager.UnmountOptions = [.withoutUI]
        if !disk.isNetwork && !keepingOtherPartitions {
            options.insert(.allPartitionsAndEjectDisk)
        }
        do {
            try await FileManager.default.unmountVolume(
                at: URL(filePath: disk.path, directoryHint: .isDirectory), options: options)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// Never the startup disk or anything the system mounts for itself.
    static func canEject(path: String) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        return standardized != "/" && !standardized.hasPrefix("/System/")
    }

    // MARK: - Hidden files

    @concurrent func showsHiddenFiles() async throws -> Bool {
        CFPreferencesAppSynchronize(Self.finderID as CFString)
        return Self.isOn(CFPreferencesCopyAppValue(Self.showAllFilesKey as CFString, Self.finderID as CFString))
    }

    @concurrent func setShowsHiddenFiles(_ shows: Bool) async throws -> Bool {
        let domain = Self.finderID as CFString
        CFPreferencesSetAppValue(Self.showAllFilesKey as CFString, shows as CFPropertyList, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw SystemFailure.failed(code: 0) }
        return try await Self.restartFinder()
    }

    /// Finder stores the setting as a Boolean, or as "YES" or "1" when someone wrote it with
    /// `defaults` as a string.
    static func isOn(_ value: CFPropertyList?) -> Bool {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "yes", "true"].contains(text.lowercased())
        default: false
        }
    }

    /// Asks Finder to quit, waits up to five seconds for it to go, then opens it again in the
    /// background. The wait checks the old process IDs, since the system may start a new Finder by
    /// itself. Returns false when Finder is still running at the deadline, as when it is busy
    /// copying; it then picks up the setting the next time it opens.
    private static func restartFinder() async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: finderID)
        let pids = running.map(\.processIdentifier).filter { $0 > 1 }
        for finder in running {
            finder.terminate()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        // Signal 0 sends nothing; it only asks whether the process still exists.
        while clock.now < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !pids.contains(where: { kill($0, 0) == 0 }) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: finder, configuration: configuration)
        } catch {
            throw SystemFailure.failed(code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        return true
    }
}
