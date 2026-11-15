import Foundation
import Kit

/// Installed applications in root search, as `app:<bundle id>`.
final class AppCatalog: CatalogSource {
    /// The namespace Kit reserves for applications. This feature is the one that owns it.
    nonisolated static let namespace = ItemID.ReservedNamespace.app

    private unowned let feature: AppsFeature

    init(feature: AppsFeature) {
        self.feature = feature
    }

    var namespace: String { Self.namespace }

    /// Sent when an app is installed, removed, launched or quit, so the Running tag stays current.
    var changes: ChangeSignal? { feature.changes }

    /// Hiding an app in settings removes it from root search at once.
    var reloadsOnSettings: [AnySettingKey] { [AppsSettings.hiddenApps.erased] }

    func rows() async throws -> [Row] {
        await feature.appRows()
    }

    /// Built from the row's payload and the running apps the feature already knows: no I/O.
    func actions(for row: Row) -> [Action] {
        feature.actions(forAppRow: row)
    }
}

/// System Settings panes and their sections in root search, as `setting:<pane id>[?<anchor>]`.
final class SettingsPaneCatalog: CatalogSource {
    nonisolated static let namespace = "setting"
    nonisolated static let subtitle = "System Settings"
    nonisolated static let settingsAppID = "com.apple.systempreferences"

    private unowned let feature: AppsFeature

    init(feature: AppsFeature) {
        self.feature = feature
    }

    var namespace: String { Self.namespace }

    /// Turning the panes off in settings removes them from root search at once.
    var reloadsOnSettings: [AnySettingKey] { [AppsSettings.showsSettingsPanes.erased] }

    func rows() async throws -> [Row] {
        guard feature.context.settings[AppsSettings.showsSettingsPanes] else { return [] }
        return await AppRows.settings(feature.settingsPanes())
    }

    /// Everything comes from the row's key, which is the deep link without its scheme.
    func actions(for row: Row) -> [Action] {
        guard let url = SettingsLink.url(forKey: row.id.key) else { return [] }
        return [
            .open(url, title: "Open in System Settings", icon: .app(bundleID: Self.settingsAppID)),
            .copy(url.absoluteString, title: "Copy Link", hud: "Copied Link", shortcut: .copy),
        ]
    }
}

/// The Running Applications page: every app with a Dock icon that runs now, with the same actions as
/// in root search.
final class RunningAppsList: ListSource {
    private unowned let feature: AppsFeature

    init(feature: AppsFeature) {
        self.feature = feature
    }

    /// Sent when an app launches, quits, hides or unhides, so the page follows along.
    var changes: ChangeSignal? { feature.changes }

    /// Reads the running apps afresh, through the feature, so the rows and their actions agree. Waits
    /// for a scan in progress, so a running app shows its installed name from the first load.
    func load(_ request: ListRequest) async throws -> ListResult {
        await feature.refreshRunning().value
        let installed = await feature.installedAfterScan()
        let rows = await AppRows.running(feature.running, installed: installed)
        return ListResult(sections: [ListSection("Running Applications", id: "running", showsCount: true, rows: rows)])
    }

    func actions(for row: Row) -> [Action] {
        feature.actions(forAppRow: row)
    }
}
