import Foundation
import Kit

/// Builds the feature's rows. Pure functions over plain values; the catalog builds several hundred
/// rows at a time, so the builders run off the main thread.
nonisolated enum AppRows {
    static let subtitle = "Application"

    /// One row per installed app, except the hidden ones.
    @concurrent static func catalog(_ apps: [InstalledApp], running: [RunningApp], hidden: Set<String>) async -> [Row] {
        let runningIDs = Set(running.compactMap(\.bundleID))
        let runningPaths = Set(running.compactMap(\.path))
        return apps.compactMap { app in
            if let bundleID = app.bundleID, hidden.contains(bundleID) { return nil }
            let isRunning = app.bundleID.map(runningIDs.contains) ?? runningPaths.contains(app.path)
            return row(app.reference, keywords: app.keywords, accessories: isRunning ? [.tag("Running")] : [])
        }
    }

    /// One row per running app. An app the scan found keeps its catalog ID and keywords, so learning
    /// and actions are shared; an app running from elsewhere, such as a disk image, gets an ID of its
    /// own.
    @concurrent static func running(_ running: [RunningApp], installed: [InstalledApp]) async -> [Row] {
        var byBundleID: [String: InstalledApp] = [:]
        for app in installed {
            if let bundleID = app.bundleID, byBundleID[bundleID] == nil { byBundleID[bundleID] = app }
        }
        return running.compactMap { app in
            let accessories: [Accessory] = app.isHidden ? [.tag("Hidden")] : []
            if let bundleID = app.bundleID, let installed = byBundleID[bundleID] {
                return row(installed.reference, keywords: installed.keywords, accessories: accessories)
            }
            guard let key = app.bundleID ?? app.path, let path = app.path else { return nil }
            let reference = AppReference(
                key: key, bundleID: app.bundleID, name: app.name, path: path, isSystem: path.hasPrefix("/System/"))
            return row(reference, keywords: [], accessories: accessories)
        }
    }

    /// An app's row. Root search offers every app again on each read, so it needs no snapshot of the
    /// row: `.learnOnly` keeps the learning and lets a hidden or deleted app drop out at once.
    static func row(_ app: AppReference, keywords: [String], accessories: [Accessory]) -> Row {
        Row(
            id: ItemID(AppCatalog.namespace, app.key), title: app.name, subtitle: subtitle, icon: icon(for: app),
            accessories: accessories, keywords: keywords, payload: Payload(app), memory: .learnOnly,
            represents: .files([app.url]))
    }

    static func icon(for app: AppReference) -> Icon {
        app.bundleID.map { .app(bundleID: $0) } ?? .file(path: app.path)
    }

    /// One row per Settings pane and one per anchor inside it, panes first.
    @concurrent static func settings(_ panes: [SystemSettingsPane]) async -> [Row] {
        var rows: [Row] = []
        for pane in panes {
            let icon: Icon =
                SettingsPaneScanner.nameOverrides[pane.id] == nil
                ? .file(path: pane.path) : .app(bundleID: SettingsPaneCatalog.settingsAppID)
            let paneKey = SettingsLink.key(pane: pane.id)
            rows.append(
                Row(
                    id: ItemID(SettingsPaneCatalog.namespace, paneKey), title: pane.name,
                    subtitle: SettingsPaneCatalog.subtitle, icon: icon,
                    keywords: [pane.name + " Settings"], memory: .learnOnly,
                    represents: SettingsLink.url(forKey: paneKey).map(Selection.url)))
            for anchor in pane.anchors {
                let key = SettingsLink.key(pane: pane.id, anchor: anchor.id)
                rows.append(
                    Row(
                        id: ItemID(SettingsPaneCatalog.namespace, key), title: anchor.title,
                        subtitle: SettingsPaneCatalog.subtitle + " › " + pane.name, icon: icon,
                        keywords: anchor.keywords, memory: .learnOnly,
                        represents: SettingsLink.url(forKey: key).map(Selection.url)))
            }
        }
        return rows
    }
}
