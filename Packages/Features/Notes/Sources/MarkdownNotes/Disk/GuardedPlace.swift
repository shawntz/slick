import Foundation

/// A place macOS guards with a prompt of its own on an app's first read. The feature reads a folder
/// there only after the user chose it, so the prompt follows something the user did.
///
/// The rules follow Platform's read guard: Desktop, Documents and Downloads; iCloud Drive and every
/// app's iCloud documents under `~/Library/Mobile Documents`; anything under `/Volumes`; and other
/// apps' data. Pure: it looks at the path only.
nonisolated enum GuardedPlace: Hashable, Sendable {
    case desktop
    case documents
    case downloads
    case iCloudDrive
    case volume
    case appData

    /// The guarded place that holds the folder, or nil when no prompt guards it.
    static func of(_ folder: URL, home: URL) -> GuardedPlace? {
        func normalized(_ url: URL) -> String {
            let path = PosixNoteDisk.comparablePath(url)
            return path.lowercased()
        }
        let path = normalized(folder)
        let home = normalized(home)
        func isInside(_ place: String) -> Bool {
            path == place || path.hasPrefix(place + "/")
        }
        if isInside(home + "/desktop") { return .desktop }
        if isInside(home + "/documents") { return .documents }
        if isInside(home + "/downloads") { return .downloads }
        if isInside(home + "/library/mobile documents") { return .iCloudDrive }
        if path.hasPrefix("/volumes/") { return .volume }
        let appData = ["containers", "group containers", "cloudstorage", "mail", "messages", "safari"]
        if appData.contains(where: { isInside(home + "/library/" + $0) }) { return .appData }
        return nil
    }
}
