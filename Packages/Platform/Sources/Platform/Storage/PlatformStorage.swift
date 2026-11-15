import Foundation
import Kit

/// The live storage service. It computes paths and touches nothing.
///
/// Layout under the data root, which the caller chooses:
///
/// ```
/// <data root>/Features/<feature id>/   data that must survive
/// <data root>/Caches/<feature id>/     data that can be rebuilt
/// <data root>/Home/                    the synthetic home, outside the live environment only
/// ```
///
/// A feature ID that is not a safe folder name is made into one, so no ID can climb out of its
/// folder. Kit's validator already rejects such IDs; this is a second guard.
nonisolated public struct PlatformStorage: StorageService {
    /// The folder that holds every feature's data.
    public let dataRoot: URL
    public let homeDirectory: URL

    /// - Parameters:
    ///   - dataRoot: The data folder for this run, such as the one ``defaultDataRoot(override:)``
    ///     returns in the app or a temporary folder elsewhere.
    ///   - homeDirectory: What features see as the home folder.
    public init(dataRoot: URL, homeDirectory: URL) {
        self.dataRoot = dataRoot
        self.homeDirectory = homeDirectory
    }

    /// Storage for a run environment. In `live` the home folder is the user's; elsewhere it is
    /// `<data root>/Home`, so a scenario that shows "~/..." never shows the real home.
    public init(dataRoot: URL, environment: RunEnvironment) {
        let home =
            environment.touchesRealSystem
            ? FileManager.default.homeDirectoryForCurrentUser
            : dataRoot.appending(path: "Home", directoryHint: .isDirectory)
        self.init(dataRoot: dataRoot, homeDirectory: home)
    }

    public func dataDirectory(for featureID: String) -> URL {
        dataRoot.appending(path: "Features", directoryHint: .isDirectory)
            .appending(path: Self.folderName(for: featureID), directoryHint: .isDirectory)
    }

    public func cacheDirectory(for featureID: String) -> URL {
        dataRoot.appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: Self.folderName(for: featureID), directoryHint: .isDirectory)
    }

    /// Where the icon cache keeps its atlases, the favicons features fill, and downloaded images:
    /// `<data root>/Caches/app.icons`, `app.favicons` and `app.remote-icons`. The names contain a
    /// ".", which no feature ID may, so they cannot clash with a feature's cache folder.
    public var iconFolders: IconCache.Folders {
        let caches = dataRoot.appending(path: "Caches", directoryHint: .isDirectory)
        return IconCache.Folders(
            atlas: caches.appending(path: "app.icons", directoryHint: .isDirectory),
            favicons: caches.appending(path: "app.favicons", directoryHint: .isDirectory),
            remote: caches.appending(path: "app.remote-icons", directoryHint: .isDirectory))
    }

    /// The app's data folder: `override` when it is set and not empty, such as the value of
    /// `SLICK_DATA_DIR` or `--data-dir`, else the brand's folder under Application Support. Only a
    /// path; nothing is created.
    public static func defaultDataRoot(override: String? = nil) -> URL {
        if let override, !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: Brand.dataDirectoryName, directoryHint: .isDirectory)
    }

    /// A folder name for a feature ID: the ID itself when it uses only letters, digits, "-" and "_"
    /// and does not start with a dot, else the ID with every other character replaced by "_".
    static func folderName(for featureID: String) -> String {
        let allowed = featureID.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
        if allowed && !featureID.isEmpty { return featureID }
        let replaced = featureID.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-") ? Character(scalar) : "_"
        }
        return "_" + String(replaced)
    }
}
