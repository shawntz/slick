import AppKit
import CoreBridge
import Foundation
import UniformTypeIdentifiers

/// The live file system service. Never run in tests.
///
/// `mountedVolumes()` asks for each mounted volume's flags, as the permission center does before it
/// probes a volume, and runs only after the user chose to search a kind of volume. `listFolder`
/// lists a folder the user typed only when ``BrowseGuard`` allows it: outside the home folder, on
/// the startup volume, and away from the places that hold other volumes or other apps' data.
/// `facts(of:)` reads one item's resource values for the detail pane, and the feature calls it only
/// for a path its scope allows, so it never touches a folder macOS guards before the user granted
/// it. `volumeChanges()` listens to the workspace's mount notifications, which read nothing.
nonisolated struct LiveFileSystem: FileSystem {
    @concurrent func mountedVolumes() async -> MountedVolumes {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        var found = MountedVolumes()
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)) else { continue }
            let path = volume.path(percentEncoded: false)
            guard path != "/" else { continue }
            if values.volumeIsLocal == false {
                found.network.append(path)
            } else if values.volumeIsRemovable == true || values.volumeIsEjectable == true {
                found.removable.append(path)
            }
        }
        return found
    }

    @concurrent func listFolder(_ folder: String, scope: ScopePlan) async -> FolderListing? {
        guard let path = BrowseGuard.live(home: scope.home, blocked: scope.blocked).listablePath(folder) else {
            return nil
        }
        return try? FileIndex.listFolder(path, rules: scope.configuration)
    }

    @concurrent func facts(of path: String) async -> FileFacts? {
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey,
            .contentTypeKey,
        ]
        guard let values = try? URL(filePath: path).resourceValues(forKeys: keys) else { return nil }
        return FileFacts(
            kind: values.localizedTypeDescription, created: values.creationDate,
            modified: values.contentModificationDate, size: values.fileSize.map(Int64.init),
            contentType: values.contentType?.identifier)
    }

    /// Mounts, unmounts and renames from the shared workspace's notification center. The observers
    /// go when the listening task ends.
    func volumeChanges() -> AsyncStream<Void> {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        return AsyncStream { continuation in
            let observers = Observers(
                names.map { name in
                    center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
                })
            continuation.onTermination = { _ in
                for observer in observers.tokens { center.removeObserver(observer) }
            }
        }
    }

    /// The tokens `addObserver` returns, kept until the stream ends. The center may be called from
    /// any thread.
    private struct Observers: @unchecked Sendable {
        let tokens: [any NSObjectProtocol]

        init(_ tokens: [any NSObjectProtocol]) {
            self.tokens = tokens
        }
    }
}
