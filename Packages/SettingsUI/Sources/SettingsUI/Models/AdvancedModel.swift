import Foundation
import Kit
import KitHosting
import LauncherUI
import Observation

/// The advanced pane: the data folder, how the panel appears, remote icons, the commands links
/// may run without asking, and a reset.
@Observable final class AdvancedModel {
    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private let links: FeatureSettings
    private let revision = Revision()

    init(context: SettingsContext) {
        self.context = context
        links = LinkAllowances.settings(context.services.settings)
        tasks.follow(HostSettings.allKeys, in: context.general, bumping: revision)
        tasks.follow([LinkAllowances.key.erased], in: links, bumping: revision)
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

    // MARK: Links

    /// One command links may run without asking, as the pane lists it.
    struct LinkAllowanceItem: Identifiable, Hashable {
        let entry: LinkAllowances.Entry
        /// The command's title now, or the title it had when the user allowed it.
        let title: String
        /// The exact arguments allowed, or a note that there are none.
        let detail: String
        var id: String { entry.storedValue }
    }

    /// Every command links may run without asking, in the order the user allowed them.
    var linkAllowances: [LinkAllowanceItem] {
        revision.track()
        return LinkAllowances.entries(in: links).map { entry in
            LinkAllowanceItem(
                entry: entry, title: context.directory.command(entry.command)?.command.title ?? entry.title,
                detail: Self.argumentsText(entry.arguments))
        }
    }

    /// Stops links from running the command without asking.
    func removeLinkAllowance(_ item: LinkAllowanceItem) {
        LinkAllowances.remove(item.entry, in: links)
        revision.bump()
    }

    /// The arguments as one line, in name order, or a note that there are none.
    static func argumentsText(_ arguments: [String: String]) -> String {
        guard !arguments.isEmpty else { return "With no arguments" }
        return "With " + arguments.keys.sorted().map { "\($0): \(arguments[$0] ?? "")" }.joined(separator: ", ")
    }

    static func title(_ strategy: HostSettings.SummonStrategy) -> String {
        switch strategy {
        case .layerOpacity: "Keep Ready"
        case .orderFront: "Bring to Front Each Time"
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
                    "General, root search and feature settings go back to their defaults. \(Brand.name) selects Standard and sets Appearance to Match System. Reset keeps your aliases, hotkeys, favorites, themes, theme changes and what root search learned.",
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
