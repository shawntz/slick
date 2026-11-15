import CoreBridge
import Kit

/// The engine's kind for an item. The engine gives apps, commands and settings a small prior
/// inside their text tier, so the kind never lifts an item past a stronger match.
nonisolated enum ItemKinds {
    /// Namespaces that hold files and folders.
    static let fileNamespaces: Set<String> = ["file", "files", "folder", "folders"]
    /// Namespaces that hold contacts.
    static let contactNamespaces: Set<String> = ["contact", "contacts", "people"]
    /// Namespaces that hold settings panes.
    static let settingNamespaces: Set<String> = ["setting", "settings", "system-settings", "preferences"]

    /// The kind from the row's namespace, or from what it stands for: a row that represents files is
    /// a file.
    static func kind(of row: Row) -> ItemKind {
        let namespace = row.id.namespace
        switch namespace {
        case ItemID.ReservedNamespace.app: return .app
        case ItemID.ReservedNamespace.command: return .command
        default: break
        }
        if case .files = row.represents { return .file }
        if fileNamespaces.contains(namespace) { return .file }
        if contactNamespaces.contains(namespace) { return .contact }
        if settingNamespaces.contains(namespace) { return .setting }
        return .other
    }
}
