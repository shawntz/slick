import Foundation

/// Where features keep their files. In the app that is the data folder under Application Support
/// (or `SLICK_DATA_DIR`); in scenarios, self-tests and tests it is a temporary folder.
///
/// Every method returns a path and touches nothing, so it is safe anywhere, including
/// ``Feature/init(context:)``. Folders are created by whatever writes first: `JSONFileStore` and
/// `SQLiteDatabase` create theirs.
public protocol StorageService: Sendable {
    /// The feature's folder for data that must survive.
    func dataDirectory(for featureID: String) -> URL

    /// The feature's folder for data that can be rebuilt.
    func cacheDirectory(for featureID: String) -> URL

    /// The user's home folder in the app, and a synthetic one elsewhere, so a scenario that shows
    /// "~/..." never shows the real home.
    var homeDirectory: URL { get }
}

/// One feature's folders. Use `KitStorage` for SQLite databases and JSON files inside them.
public struct FeatureStorage: Sendable {
    public let featureID: String
    private let service: any StorageService

    public init(featureID: String, service: any StorageService) {
        self.featureID = featureID
        self.service = service
    }

    /// The feature's data folder. It may not exist yet.
    public var dataDirectory: URL {
        service.dataDirectory(for: featureID)
    }

    /// The feature's cache folder. It may not exist yet.
    public var cacheDirectory: URL {
        service.cacheDirectory(for: featureID)
    }

    /// The home folder for this run environment.
    public var homeDirectory: URL {
        service.homeDirectory
    }

    /// A file in the data folder, such as `dataFile("quicklinks.json")`. Only a path.
    public func dataFile(_ name: String) -> URL {
        dataDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    /// A file in the cache folder. Only a path.
    public func cacheFile(_ name: String) -> URL {
        cacheDirectory.appending(path: name, directoryHint: .notDirectory)
    }
}
