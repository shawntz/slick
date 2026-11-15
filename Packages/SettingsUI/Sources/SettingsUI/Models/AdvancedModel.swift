import Foundation
import Kit
import KitHosting
import LauncherUI
import Observation

/// The advanced pane: the data folder, how the panel appears, remote icons, and a reset.
@Observable final class AdvancedModel {
    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()

    init(context: SettingsContext) {
        self.context = context
        tasks.follow(HostSettings.allKeys, in: context.general, bumping: revision)
    }

    var dataDirectory: URL { context.dependencies.dataDirectory }

    /// The data folder with the home folder shortened to "~".
    var dataDirectoryText: String {
        let path = dataDirectory.path
        let home = context.services.storage.homeDirectory.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    func revealDataDirectory() async {
        await context.services.workspace.reveal([dataDirectory])
    }

    var summonStrategy: HostSettings.SummonStrategy {
        get {
            revision.track()
            return context.general[HostSettings.summonStrategy]
        }
        set {
            context.general[HostSettings.summonStrategy] = newValue
            revision.bump()
        }
    }

    var fetchRemoteIcons: Bool {
        get {
            revision.track()
            return context.general[HostSettings.fetchRemoteIcons]
        }
        set {
            context.general[HostSettings.fetchRemoteIcons] = newValue
            revision.bump()
        }
    }

    static func title(_ strategy: HostSettings.SummonStrategy) -> String {
        switch strategy {
        case .layerOpacity: "Keep ready, fastest"
        case .orderFront: "Bring to front each time"
        }
    }

    /// Resets the general settings and every setting a feature's pane shows, after the user
    /// confirms. Onboarding is not shown again. Aliases, hotkeys, favorites, theme files, secrets
    /// and what was learned stay.
    func resetAllSettings() async {
        let confirmed = await context.confirmations.ask(
            Confirmation(
                "Reset all settings?",
                message:
                    "General, root search and feature settings go back to their defaults, and the Standard theme is selected. Aliases, hotkeys, favorites, your theme files and what was learned are kept.",
                confirmTitle: "Reset", isDestructive: true))
        guard confirmed else { return }
        let general = context.general
        for key in HostSettings.allKeys where key.name != HostSettings.onboardingDone.name {
            general.write(nil, for: key)
        }
        for feature in context.directory.features {
            let keys = feature.settingsPane?.sections.flatMap(\.items).compactMap(\.control.key) ?? []
            for key in keys { feature.context.settings.write(nil, for: key) }
        }
        context.dependencies.themes.select(ThemeStore.standardName)
        context.toasts.show(.success("Settings reset"))
        revision.bump()
    }
}
