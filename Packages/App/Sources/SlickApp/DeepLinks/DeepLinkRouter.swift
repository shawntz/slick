import Foundation
import Host
import Kit
import KitHosting
import SettingsUI
import os

/// Acts on deep links. Opening the launcher and settings happens at once. A command never runs
/// silently: unless the user chose to always allow that command from links, the panel opens on a
/// page that names the command and its arguments and offers Run Once, Always Allow and Cancel.
@MainActor final class DeepLinkRouter {
    /// What a link did, for tests and scenarios.
    enum Outcome: Equatable {
        case openedLauncher(query: String?)
        case asked(ItemID)
        case ran(ItemID)
        case openedSettings(SettingsPaneID?)
        case openedFeatureSettings(String)
        case refused(DeepLinkError)
    }

    /// Where the always-allowed commands are stored, beside ``HostSettings``.
    static let settingsNamespace = "app.links"
    static let allowedCommands = SettingKey("allowedCommands", default: [String]())

    private let runtime: FeatureRuntime
    private let panel: PanelController?
    private let settings: SettingsOpener
    private let store: FeatureSettings
    private let log = KitLog.logger(category: "app.links")
    /// The latest outcomes, oldest first, for scenarios and tests.
    private(set) var outcomes: [Outcome] = []
    /// How many outcomes ``outcomes`` keeps.
    static let keptOutcomes = 64

    init(runtime: FeatureRuntime, panel: PanelController?, settings: SettingsOpener) {
        self.runtime = runtime
        self.panel = panel
        self.settings = settings
        store = FeatureSettings(featureID: Self.settingsNamespace, service: runtime.services.settings)
    }

    /// The commands that run from links without asking, as `cmd:` IDs.
    var alwaysAllowed: Set<ItemID> {
        Set(store[Self.allowedCommands].compactMap(ItemID.init(rawValue:)))
    }

    /// Reads a URL and acts on it. Returns what it did.
    @discardableResult
    func handle(_ url: URL) -> Outcome {
        let outcome: Outcome
        do {
            outcome = try act(on: try DeepLink.parse(url))
        } catch {
            log.error("refused a link: \(String(describing: error), privacy: .public)")
            outcome = .refused(error)
        }
        outcomes.append(outcome)
        // The live app handles links for as long as it runs; keep only the recent ones.
        if outcomes.count > Self.keptOutcomes { outcomes.removeFirst(outcomes.count - Self.keptOutcomes) }
        return outcome
    }

    /// Checks a parsed link against what exists, then acts on it.
    func act(on link: DeepLink) throws(DeepLinkError) -> Outcome {
        switch link {
        case .open(let query):
            openLauncher(query: query)
            return .openedLauncher(query: query)
        case .settings(let name):
            var pane: SettingsPaneID?
            if let name {
                guard let found = SettingsPaneID.allCases.first(where: { $0.rawValue == name }) else {
                    throw .unknownPane
                }
                pane = found
            }
            settings.open(pane)
            return .openedSettings(pane)
        case .featureSettings(let featureID):
            guard runtime.feature(featureID) != nil else { throw .unknownFeature }
            settings.openFeature(featureID)
            return .openedFeatureSettings(featureID)
        case .command(let featureID, let commandID, let arguments):
            let id = ItemID.command(feature: featureID, command: commandID)
            guard let entry = runtime.command(id) else { throw .unknownCommand }
            guard entry.isEnabled else { throw .commandOff }
            let declared = Set(entry.command.arguments.map(\.name))
            if let unknown = arguments.keys.sorted().first(where: { !declared.contains($0) }) {
                throw .unknownArgument(unknown)
            }
            if alwaysAllowed.contains(id) {
                run(id, arguments: arguments)
                return .ran(id)
            }
            ask(entry, arguments: arguments)
            return .asked(id)
        }
    }

    // MARK: Acting

    private func openLauncher(query: String?) {
        guard let panel else { return }
        panel.popToRoot()
        panel.summon()
        panel.setQuery(query ?? "")
    }

    private func run(_ id: ItemID, arguments: [String: String]) {
        panel?.popToRoot()
        runtime.pipeline.runCommand(id, arguments: arguments, launch: .deeplink)
    }

    /// Stores that the command may run from links without asking.
    func allowAlways(_ id: ItemID) {
        var stored = store[Self.allowedCommands]
        guard !stored.contains(id.rawValue) else { return }
        stored.append(id.rawValue)
        store[Self.allowedCommands] = stored.sorted()
    }

    /// Opens the panel on a page that asks before the command runs.
    private func ask(_ entry: CommandEntry, arguments: [String: String]) {
        guard let panel else { return }
        let id = entry.id
        let title = entry.command.title
        let detail = AppStrings.linkArguments(arguments)
        let runOnce = Row(
            id: ItemID("app-link", "run"), title: AppStrings.linkRunOnce(title), subtitle: detail,
            icon: .symbol("play.fill"), memory: .never)
        let always = Row(
            id: ItemID("app-link", "always"), title: AppStrings.linkAlwaysAllow,
            subtitle: AppStrings.linkAlwaysAllowDetail(title), icon: .symbol("checkmark.shield"), memory: .never)
        let cancel = Row(
            id: ItemID("app-link", "cancel"), title: AppStrings.linkCancel, icon: .symbol("xmark"), memory: .never)
        let page = ListPage(
            sections: [ListSection(AppStrings.linkSection, id: "link", rows: [runOnce, always, cancel])],
            title: AppStrings.linkPageTitle,
            actions: { [weak self] row in
                let key = row.id.key
                let label =
                    switch key {
                    case "run": AppStrings.linkRunOnce(title)
                    case "always": AppStrings.linkAlwaysAllow
                    default: AppStrings.linkCancel
                    }
                return [
                    Action(label, id: "link." + key) { _ in
                        guard let self else { return .keepOpen }
                        switch key {
                        case "run":
                            self.run(id, arguments: arguments)
                            return .keepOpen
                        case "always":
                            self.allowAlways(id)
                            self.run(id, arguments: arguments)
                            return .keepOpen
                        default:
                            return .popToRoot
                        }
                    }
                ]
            })
        let origin = RunOrigin(
            featureID: HostSettings.namespace, feature: runtime.hostContext, launch: .deeplink)
        panel.popToRoot()
        panel.summon()
        panel.push(panel.makePage(.list(page), origin: origin))
    }
}
