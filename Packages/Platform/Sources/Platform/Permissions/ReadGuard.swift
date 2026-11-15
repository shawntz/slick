import Foundation
import Kit

/// Decides whether a service may read a path on its own, when no user action asked for that read.
///
/// Reading in a protected folder, on a removable or network volume, or in another app's data can
/// make macOS show a prompt. The icon loader and the app catalog read files in the background, so
/// they ask the guard first and fall back to something that reads nothing, such as a file type's
/// generic icon. ``permissions(_:home:)`` is the live guard.
nonisolated public struct ReadGuard: Sendable {
    private let allows: @Sendable (URL) -> Bool

    public init(_ allows: @escaping @Sendable (URL) -> Bool) {
        self.allows = allows
    }

    /// Reads anywhere. For tests and for run environments other than `live`, whose paths are
    /// synthetic.
    public static let anywhere = ReadGuard { _ in true }

    /// Reads where no permission guards the path, or where every permission the path needs is
    /// granted. Reads only the permission statuses, which never prompt.
    public static func permissions(_ permissions: any PermissionService, home: URL) -> ReadGuard {
        ReadGuard { url in
            ProtectedLocations.permissionsNeeded(toRead: url, home: home).allSatisfy {
                permissions.status(of: $0) == .granted
            }
        }
    }

    /// True when reading at the URL cannot make macOS ask the user.
    public func mayRead(_ url: URL) -> Bool {
        allows(url)
    }
}
