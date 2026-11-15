import Foundation
import Kit

/// A mounted disk that can be ejected: an external drive, a disk image or a network volume.
nonisolated struct Disk: Hashable, Sendable {
    /// The name Finder shows.
    var name: String
    /// Where it is mounted.
    var path: String
    /// True for a server volume, which is disconnected rather than ejected.
    var isNetwork: Bool
}

/// How emptying the Trash went.
nonisolated struct TrashResult: Hashable, Sendable {
    var deleted: Int
    /// Items that could not be deleted, such as those in use.
    var failed: Int
}

/// The Trash, mounted disks and Finder's hidden files setting.
///
/// The live implementation deletes the user's files and ejects their disks. Tests, scenarios,
/// self-tests and benchmarks get ``SimulatedHousekeeping``, which keeps everything in memory.
nonisolated protocol HousekeepingService: Sendable {
    /// How many items are in the Trash. `includingVolumes` adds the Trash folders on other mounted
    /// disks. Throws ``SystemFailure/permissionMissing(_:)`` when macOS keeps the Trash from this app.
    @concurrent func trashItemCount(includingVolumes: Bool) async throws -> Int

    /// Deletes every item in the Trash for good.
    @concurrent func emptyTrash(includingVolumes: Bool) async throws -> TrashResult

    /// The disks that can be ejected now, in the order macOS lists them. The startup disk and
    /// internal volumes are never among them.
    @concurrent func ejectableDisks() async throws -> [Disk]

    /// Ejects one disk. With `keepingOtherPartitions`, only this volume is unmounted and other
    /// volumes on the same drive stay; otherwise the whole drive is ejected, as Finder does.
    @concurrent func eject(_ disk: Disk, keepingOtherPartitions: Bool) async throws

    /// Whether Finder shows hidden files.
    @concurrent func showsHiddenFiles() async throws -> Bool

    /// Makes Finder show or hide hidden files. Finder restarts to apply it. Returns false when
    /// Finder did not quit in time, so the change applies the next time it opens.
    @concurrent func setShowsHiddenFiles(_ shows: Bool) async throws -> Bool
}

/// The names in "Never eject", as the user typed them. Case and width do not matter, spaces at
/// either end are ignored, and `*` matches any run of characters, so "Backup*" keeps every disk
/// whose name starts with "Backup".
nonisolated enum DiskNamePattern {
    static func matches(_ name: String, any patterns: [String]) -> Bool {
        let name = folded(name)
        return patterns.contains { matches(name, folded: folded($0)) }
    }

    /// Matches a folded name against one folded pattern. An empty pattern matches nothing.
    private static func matches(_ name: String, folded pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return name == pattern }
        var rest = Substring(name)
        // The first part must start the name and the last must end it. The parts between must
        // appear in order.
        guard let first = parts.first, rest.hasPrefix(first) else { return false }
        rest = rest.dropFirst(first.count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let found = rest.range(of: part) else { return false }
            rest = rest[found.upperBound...]
        }
        let last = parts.last ?? ""
        return rest.count >= last.count && rest.hasSuffix(last)
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The housekeeping service for each kind of run.
nonisolated enum HousekeepingServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any HousekeepingService {
        LiveHousekeeping()
    }

    static func isolated(_ context: FeatureContext) -> any HousekeepingService {
        SimulatedHousekeeping(
            trashItems: 3,
            disks: [
                Disk(name: "Example Drive", path: "/Volumes/Example Drive", isNetwork: false),
                Disk(name: "Example Server", path: "/Volumes/Example Server", isNetwork: true),
            ])
    }
}
