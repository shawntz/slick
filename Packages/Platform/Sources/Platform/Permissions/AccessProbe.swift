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

    /// The folders that stand for a protected folder permission. Removable and network volumes are
    /// probed through whatever such volumes are mounted, so there may be none.
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
    /// - Other apps' data, iCloud Drive, cloud storage folders, Mail and Messages need Full Disk
    ///   Access, which also grants every folder permission.
    static func permissionsNeeded(toRead url: URL, home: URL) -> [Permission] {
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false).lowercased()
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let path = normalized(url)
        let home = normalized(home)
        func isInside(_ folder: String) -> Bool {
            path == folder || path.hasPrefix(folder + "/")
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
        let guardedLibraries = [
            "Containers", "Group Containers", "Mobile Documents", "CloudStorage", "Mail", "Messages", "Safari",
        ]
        if guardedLibraries.contains(where: { isInside(home + "/library/" + $0.lowercased()) }) {
            return [.fullDiskAccess]
        }
        return []
    }

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
