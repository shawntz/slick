import Darwin
import Foundation
import Kit

/// Finds out whether a protected location is readable by reading it. Reading a protected folder is
/// what makes macOS show its folder prompt, so a folder probe runs only from
/// ``MacPermissionSystem/request(_:)``, right after the user pressed Grant. The Full Disk Access
/// probe also runs from ``MacPermissionSystem/recheck(_:)``. No probe reads another app's data,
/// whose refusal posts TCC's "Data Access Blocked" notification. Nothing read is kept or logged.
nonisolated enum AccessProbe {
    /// One place to read.
    struct Target: Hashable, Sendable {
        var url: URL
        var isDirectory: Bool
    }

    /// The first conclusive answer among the targets: granted when one is readable, denied when
    /// the system refuses. Missing targets are skipped. Nil when none was conclusive.
    static func run(_ targets: [Target]) -> PermissionStatus? {
        for target in targets {
            if let status = probe(target) { return status }
        }
        return nil
    }

    private static func probe(_ target: Target) -> PermissionStatus? {
        let path = target.url.path(percentEncoded: false)
        if target.isDirectory {
            guard let directory = opendir(path) else { return status(forErrno: errno) }
            defer { closedir(directory) }
            errno = 0
            // One entry is enough to know the folder can be listed; its name is dropped.
            _ = readdir(directory)
            return errno == 0 ? .granted : status(forErrno: errno)
        }
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { return status(forErrno: errno) }
        close(descriptor)
        return .granted
    }

    /// Denied for a refusal, nil for anything else, such as a missing file.
    static func status(forErrno code: Int32) -> PermissionStatus? {
        code == EPERM || code == EACCES ? .denied : nil
    }
}

/// Where the probes look. Pure, so tests can check the paths without reading them.
nonisolated enum ProtectedLocations {
    /// Places only Full Disk Access opens, most specific first: the Time Machine settings, then the
    /// Mail and Messages libraries. Browser data is left out on purpose: macOS 27 guards it
    /// separately and may refuse it even with Full Disk Access.
    static func fullDiskAccessTargets(home: URL) -> [AccessProbe.Target] {
        [
            AccessProbe.Target(
                url: URL(filePath: "/Library/Preferences/com.apple.TimeMachine.plist"), isDirectory: false),
            AccessProbe.Target(
                url: home.appending(path: "Library/Mail", directoryHint: .isDirectory), isDirectory: true),
            AccessProbe.Target(
                url: home.appending(path: "Library/Messages", directoryHint: .isDirectory), isDirectory: true),
        ]
    }

    /// The iCloud Drive folder in the home folder.
    static func iCloudDrive(home: URL) -> URL {
        home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    /// The folders that stand for a protected folder permission. Removable and network volumes are
    /// probed through whatever such volumes are mounted, so there may be none. iCloud Drive is probed
    /// through its folder, which is missing when iCloud Drive is off: the probe then has no answer.
    static func targets(
        for folder: ProtectedFolder, home: URL, removableVolumes: [URL], networkVolumes: [URL]
    ) -> [AccessProbe.Target] {
        let urls: [URL] =
            switch folder {
            case .desktop: [home.appending(path: "Desktop", directoryHint: .isDirectory)]
            case .documents: [home.appending(path: "Documents", directoryHint: .isDirectory)]
            case .downloads: [home.appending(path: "Downloads", directoryHint: .isDirectory)]
            case .removableVolumes: removableVolumes
            case .networkVolumes: networkVolumes
            case .iCloudDrive: [iCloudDrive(home: home)]
            }
        return urls.map { AccessProbe.Target(url: $0, isDirectory: true) }
    }

    /// The permissions a read at `url` may need. Reading there without them can make macOS show a
    /// prompt, so a service that reads on its own, such as the icon loader, reads there only once
    /// every one is granted. Empty for a place no permission guards. Pure: it looks at the path
    /// only.
    ///
    /// - The Desktop, Documents and Downloads folders need their folder permission.
    /// - Anything under `/Volumes` may be a removable or a network volume, so it needs both.
    /// - Anything under `~/Library/Mobile Documents` needs iCloud Drive's own grant. That folder
    ///   holds iCloud Drive and every app's iCloud documents, and macOS guards all of it with the
    ///   iCloud Drive service. Full Disk Access does not count there, because whether it spares that
    ///   prompt is not known. Files kept only in iCloud would also download on a read.
    /// - Other apps' data, cloud storage folders, Mail, Messages, the Contacts, Calendars and
    ///   Reminders data, cookies, Home, Siri suggestions, call history, the privacy database and any
    ///   Photos library need Full Disk Access, which also grants Desktop, Documents, Downloads and
    ///   the volumes.
    ///
    /// A path on the data volume, `/System/Volumes/Data/...`, counts as the same path without that
    /// part. The system joins the two through firmlinks, which are not symbolic links, so the walk
    /// in ``mayRead(_:home:isGranted:linkDestination:)`` cannot see them.
    static func permissionsNeeded(toRead url: URL, home: URL) -> [Permission] {
        func normalized(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false).lowercased()
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == dataVolume { return "/" }
            if path.hasPrefix(dataVolume + "/") { path.removeFirst(dataVolume.count) }
            return path
        }
        let path = normalized(url)
        let home = normalized(home)
        func isInside(_ folder: String) -> Bool {
            path == folder || path.hasPrefix(folder + "/")
        }
        // Photos guards the library it uses, wherever it is kept.
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return [.fullDiskAccess]
        }
        let homeFolders: [(String, ProtectedFolder)] = [
            ("Desktop", .desktop), ("Documents", .documents), ("Downloads", .downloads),
        ]
        for (name, folder) in homeFolders where isInside(home + "/" + name.lowercased()) {
            return [.protectedFolder(folder)]
        }
        if path.hasPrefix("/volumes/"), path.count > "/volumes/".count {
            return [.protectedFolder(.removableVolumes), .protectedFolder(.networkVolumes)]
        }
        if isInside(home + "/library/mobile documents") {
            return [.protectedFolder(.iCloudDrive)]
        }
        if guardedLibraries.contains(where: { isInside(home + "/library/" + $0.lowercased()) }) {
            return [.fullDiskAccess]
        }
        return []
    }

    /// Where the data volume is mounted. Its folders are the same as those without this part.
    static let dataVolume = "/system/volumes/data"

    /// Folders in the home folder's Library that only Full Disk Access opens to a background read.
    static let guardedLibraries = [
        "Containers", "Group Containers", "CloudStorage", "Mail", "Messages", "Safari", "Calendars", "Reminders",
        "Cookies", "HomeKit", "Suggestions", "Application Support/AddressBook", "Application Support/CallHistoryDB",
        "Application Support/com.apple.TCC",
    ]

    /// Mounted volumes that are removable, or that are not local. Reads volume metadata only.
    static func mountedVolumes(network: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        return volumes.filter { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)) else { return false }
            if network { return values.volumeIsLocal == false }
            return values.volumeIsLocal == true
                && (values.volumeIsRemovable == true || values.volumeIsEjectable == true)
        }
    }
}
