import Foundation
import Kit

/// Decides whether a service may read a path on its own, when no user action asked for that read.
///
/// Reading in a protected folder, on a removable or network volume, or in another app's data can
/// make macOS show a prompt. The icon loader and the app catalog read files in the background, so
/// they ask the guard first and fall back to something that reads nothing, such as a file type's
/// generic icon. ``permissions(_:home:)`` is the live guard. It follows symbolic links, so a link
/// that leads into a protected place counts as that place. Ask it off the main thread: it reads
/// link metadata outside protected places.
nonisolated public struct ReadGuard: Sendable {
    private let allows: @Sendable (URL) -> Bool

    public init(_ allows: @escaping @Sendable (URL) -> Bool) {
        self.allows = allows
    }

    /// Reads anywhere. For tests and for run environments other than `live`, whose paths are
    /// synthetic.
    public static let anywhere = ReadGuard { _ in true }

    /// Reads where no permission guards the path, or where every permission the path needs is
    /// granted, with symbolic links followed. Reads the permission statuses, which never prompt,
    /// and the links on the way, only where the path so far needs nothing missing.
    public static func permissions(_ permissions: any PermissionService, home: URL) -> ReadGuard {
        ReadGuard { url in
            ProtectedLocations.mayRead(url, home: home) { permissions.status(of: $0) == .granted }
        }
    }

    /// True when reading at the URL cannot make macOS ask the user.
    public func mayRead(_ url: URL) -> Bool {
        allows(url)
    }
}

nonisolated extension ProtectedLocations {
    /// The most symbolic links one walk follows, as many as macOS follows in one path.
    static let maximumLinks = 32

    /// True when a read at `url` needs no permission that `isGranted` lacks, with every symbolic
    /// link on the way followed.
    ///
    /// The path as written is judged first, before anything is read. Then ``walk(_:linkDestination:allows:)``
    /// follows the path's links and judges each part before it asks whether that part is a link,
    /// so finding a link never touches a protected place. A link that leads into one counts as
    /// that place.
    ///
    /// - Parameter linkDestination: What the symbolic link at a path points to, as written in the
    ///   link, or nil when the path is not a link. The default reads the file system.
    static func mayRead(
        _ url: URL, home: URL, isGranted: (Permission) -> Bool,
        linkDestination: (String) -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }
    ) -> Bool {
        guard permissionsNeeded(toRead: url, home: home).allSatisfy(isGranted) else { return false }
        // Walked paths hold no links, so they are compared with the home folder without its own.
        let homePath = home.path(percentEncoded: false)
        let realHome = URL(
            filePath: walk(homePath, linkDestination: linkDestination) { _ in true } ?? homePath,
            directoryHint: .isDirectory)
        let walked = walk(url.path(percentEncoded: false), linkDestination: linkDestination) { path in
            permissionsNeeded(toRead: URL(filePath: path), home: realHome).allSatisfy(isGranted)
        }
        return walked != nil
    }

    /// Follows every symbolic link in an absolute `path` and returns the path without links, or nil
    /// when `allows` refused a part or there were more than ``maximumLinks`` links, as in a loop.
    ///
    /// It walks from the root one part at a time. Each part is shown to `allows` as the path up to
    /// it, without links, before `linkDestination` is asked about it. A link puts its destination in
    /// place of itself, and `..` after a link goes up from where the link led, as the system does.
    static func walk(_ path: String, linkDestination: (String) -> String?, allows: (String) -> Bool) -> String? {
        var walked: [Substring] = []
        // The parts still to walk, last first.
        var parts = Array(path.split(separator: "/").reversed())
        var links = 0
        while let part = parts.popLast() {
            if part == "." { continue }
            if part == ".." {
                _ = walked.popLast()
                continue
            }
            let current = "/" + (walked + [part]).joined(separator: "/")
            guard allows(current) else { return nil }
            guard let destination = linkDestination(current) else {
                walked.append(part)
                continue
            }
            links += 1
            guard links <= maximumLinks else { return nil }
            if destination.hasPrefix("/") { walked = [] }
            parts += destination.split(separator: "/").reversed()
        }
        return "/" + walked.joined(separator: "/")
    }
}
