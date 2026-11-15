import Foundation
import Kit

/// System commands: the things people do from a launcher instead of hunting through menus.
///
/// - Power and session: Sleep, Sleep Displays, Lock Screen, Start Screen Saver, Log Out, Restart and
///   Shut Down. The last three always ask first.
/// - Housekeeping: Open Trash, Empty Trash, Eject All Disks and Toggle Hidden Files.
/// - Appearance: Toggle Dark Mode.
/// - Sound: Mute, Unmute, Toggle Mute, Volume Up, Volume Down and Set Volume.
/// - Processes: Kill Process, a live list with Quit and Force Quit.
///
/// Each group sits behind a service of its own, named by a `FeatureServiceKey`, so tests and
/// scenarios run every command against simulated services and nothing touches the Mac. Quit All
/// Applications belongs to the Applications feature.
public final class SystemFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "system", name: Strings.featureName, icon: .symbol("power"), summary: Strings.featureSummary,
        permissions: [
            PermissionNeed(.fullDiskAccess, reason: Strings.Reasons.fullDiskAccess),
            PermissionNeed(.automation(bundleID: LiveAppearance.systemEventsID), reason: Strings.Reasons.systemEvents),
            PermissionNeed(.automation(bundleID: LivePower.loginWindowID), reason: Strings.Reasons.loginWindow),
        ])

    let context: FeatureContext
    let power: any PowerService
    let housekeeping: any HousekeepingService
    let appearance: any AppearanceService
    let sound: any SoundService
    let processes: any ProcessTable

    /// Does no I/O. The services touch nothing until a command runs.
    public init(context: FeatureContext) {
        self.context = context
        power = context.service(PowerServiceKey.self)
        housekeeping = context.service(HousekeepingServiceKey.self)
        appearance = context.service(AppearanceServiceKey.self)
        sound = context.service(SoundServiceKey.self)
        processes = context.service(ProcessTableKey.self)
    }

    public var commands: [Command] {
        powerCommands + housekeepingCommands + appearanceCommands + soundCommands + processCommands
    }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.Settings.sound,
                items: [
                    .picker(
                        Strings.Settings.volumeStep, key: SystemSettings.volumeStep,
                        info: Strings.Settings.volumeStepInfo, titles: Strings.Settings.volumeStepOption)
                ]),
            SettingsSection(
                Strings.Settings.disks,
                items: [
                    .toggle(
                        Strings.Settings.ejectsNetworkVolumes, key: SystemSettings.ejectsNetworkVolumes,
                        info: Strings.Settings.ejectsNetworkVolumesInfo),
                    .list(
                        Strings.Settings.neverEject, key: SystemSettings.neverEject,
                        placeholder: Strings.Settings.neverEjectPlaceholder, info: Strings.Settings.neverEjectInfo),
                ]),
            SettingsSection(
                Strings.Settings.processes,
                items: [
                    .picker(
                        Strings.Settings.sortBy, key: SystemSettings.processSort, info: Strings.Settings.sortByInfo,
                        titles: Strings.Processes.sortOption),
                    .picker(
                        Strings.Settings.refresh, key: SystemSettings.processRefresh,
                        info: Strings.Settings.refreshInfo, titles: Strings.Settings.refreshOption),
                    .toggle(
                        Strings.Settings.showsBackground, key: SystemSettings.showsBackgroundProcesses,
                        info: Strings.Settings.showsBackgroundInfo),
                ]),
            SettingsSection(
                Strings.Settings.permissions, footer: Strings.Settings.confirmationsNote,
                items: [
                    .permission(.fullDiskAccess, info: Strings.Settings.fullDiskAccessInfo),
                    .permission(
                        .automation(bundleID: LiveAppearance.systemEventsID), info: Strings.Settings.systemEventsInfo),
                    .permission(.automation(bundleID: LivePower.loginWindowID), info: Strings.Settings.loginWindowInfo),
                ]),
        ])
    }
}
