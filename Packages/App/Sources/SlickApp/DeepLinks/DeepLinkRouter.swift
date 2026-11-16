import Foundation
import Host
import Kit
import KitHosting
import SettingsUI
import os

/// Acts on deep links. Opening the launcher and settings happens at once, but a link that opens
/// the launcher selects no row, so Return runs nothing the link chose. A command never runs
/// silently: unless the user chose to always allow that command from links, the panel opens on a
/// page that names the command and its arguments and offers Run, Always Allow and Cancel, with
/// Cancel selected and Run and Always Allow waiting a second. Always Allow covers exactly the
/// arguments shown, and only while the command keeps its title: see ``LinkAllowances``. A command
/// that keeps out of deep links, with `allowsDeepLinks: false`, is refused before that page shows,
/// even when the user chose Always Allow for it. A panel session a link opened copies instead of
/// pasting.
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

    private let runtime: FeatureRuntime
    private let panel: PanelController?
    private let settings: SettingsOpener
    private let store: FeatureSettings
    private let log = KitLog.logger(category: "app.links")
    /// The latest outcomes, oldest first, for scenarios and tests.
    private(set) var outcomes: [Outcome] = []
    /// How many outcomes ``outcomes`` keeps.
    static let keptOutcomes = 64
    /// What the page that asks counts its wait on. The services' clock; tests replace it.
    var clock: any ClockService

    init(runtime: FeatureRuntime, panel: PanelController?, settings: SettingsOpener) {
        self.runtime = runtime
        self.panel = panel
        self.settings = settings
        clock = runtime.services.clock
        store = LinkAllowances.settings(runtime.services.settings)
    }

    /// The commands that run from links without asking, each with the exact arguments allowed.
    var alwaysAllowed: [LinkAllowances.Entry] {
        LinkAllowances.entries(in: store)
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
            guard entry.command.allowsDeepLinks else { throw .commandRefusesLinks }
            let declared = Set(entry.command.arguments.map(\.name))
            if let unknown = arguments.keys.sorted().first(where: { !declared.contains($0) }) {
                throw .unknownArgument(unknown)
            }
            dropGoneAllowances()
            if LinkAllowances.allows(id, arguments: arguments, title: entry.command.title, in: store) {
                run(id, arguments: arguments)
                return .ran(id)
            }
            ask(entry, arguments: arguments)
            return .asked(id)
        }
    }

    // MARK: Acting

    /// Opens root search with the link's text typed and no row selected, so Return runs nothing
    /// until the user types or moves the selection.
    private func openLauncher(query: String?) {
        panel?.showRootForLink(query: query ?? "")
    }

    private func run(_ id: ItemID, arguments: [String: String]) {
        panel?.popToRoot()
        runtime.pipeline.runCommand(id, arguments: arguments, launch: .deeplink)
    }

    /// Stores that the command may run from links without asking, with exactly these arguments
    /// and while it keeps its title.
    func allowAlways(_ entry: CommandEntry, arguments: [String: String]) {
        LinkAllowances.add(
            LinkAllowances.Entry(command: entry.id, arguments: arguments, title: entry.command.title), in: store)
    }

    /// Drops every allowance whose command is gone or has another title now, so a script saved
    /// later where an allowed one was does not inherit it. Runs before each command link. A
    /// command of a feature that is switched off stays known, so its allowances stay; Script
    /// Commands lists no scripts while it is off, so theirs go.
    func dropGoneAllowances() {
        let runtime = runtime
        let dropped = LinkAllowances.removeAll(in: store) { allowance in
            runtime.command(allowance.command)?.command.title == allowance.title
        }
        if dropped > 0 { log.info("dropped \(dropped, privacy: .public) link allowances") }
    }

    /// Opens the panel on a page that asks before the command runs, with Cancel selected. See
    /// ``LinkConsentSource`` for the wait before Run and Always Allow work.
    private func ask(_ entry: CommandEntry, arguments: [String: String]) {
        guard let panel else { return }
        let id = entry.id
        let source = LinkConsentSource(
            commandTitle: entry.command.title, arguments: arguments,
            alwaysDetail: AppStrings.linkAlwaysAllowDetail(entry.command.title, hasArguments: !arguments.isEmpty),
            clock: clock
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .run:
                run(id, arguments: arguments)
            case .always:
                allowAlways(entry, arguments: arguments)
                run(id, arguments: arguments)
            case .cancel:
                break
            }
        }
        let origin = RunOrigin(featureID: HostSettings.namespace, feature: runtime.hostContext, launch: .deeplink)
        let page = panel.makePage(.list(ListPage(source, title: AppStrings.linkPageTitle)), origin: origin)
        (page as? ListPageController)?.preferredSelection = LinkConsentSource.cancelID
        panel.pushForLink(page)
    }
}
