import Foundation

/// The live file system service. Never run in tests.
///
/// `mountedVolumes()` asks for each mounted volume's flags, as the permission center does before it
/// probes a volume, and runs only after the user chose to search a kind of volume. `names(in:)`
/// lists the home folder's Library and its Mobile Documents folder, only after iCloud Drive was
/// chosen or Full Disk Access covers it: listing Mobile Documents is the read macOS guards for
/// iCloud Drive. `facts(of:)` reads one item's resource values for the detail pane, and the
/// feature calls it only for a path its scope allows, so it never touches a folder macOS guards
/// before the user granted it.
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

    @concurrent func names(in folder: String) async -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder)
    }

    @concurrent func facts(of path: String) async -> FileFacts? {
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let values = try? URL(filePath: path).resourceValues(forKeys: keys) else { return nil }
        return FileFacts(
            kind: values.localizedTypeDescription, created: values.creationDate,
            modified: values.contentModificationDate, size: values.fileSize.map(Int64.init))
    }
}
