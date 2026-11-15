import Foundation
import Kit

/// Storage in a fresh temporary folder, removed when the fake is released. Each feature gets
/// `<root>/data/<id>` and `<root>/cache/<id>`, and the home folder is `<root>/home`. Like the live
/// service it only hands out paths; whatever writes first creates the folders.
public final class FakeStorage: StorageService {
    /// The folder that holds everything.
    public let root: URL

    /// - Parameter root: Where to put the folders. Defaults to a new folder under the system's
    ///   temporary directory, which honors `TMPDIR`.
    public init(root: URL? = nil) {
        self.root =
            root ?? FileManager.default.temporaryDirectory.appending(path: "kit-fake-storage-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    public func dataDirectory(for featureID: String) -> URL {
        root.appending(path: "data", directoryHint: .isDirectory).appending(
            path: featureID, directoryHint: .isDirectory)
    }

    public func cacheDirectory(for featureID: String) -> URL {
        root.appending(path: "cache", directoryHint: .isDirectory).appending(
            path: featureID, directoryHint: .isDirectory)
    }

    public var homeDirectory: URL {
        root.appending(path: "home", directoryHint: .isDirectory)
    }
}
