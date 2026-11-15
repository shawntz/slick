import AppKit
import Kit
import KitHosting
import LauncherUI

/// Asks for a command's arguments in the search field, for a command run without its required
/// ones, as from an action, a hotkey or a link.
///
/// The page shows the command's row alone. The panel puts the command's argument chips in the
/// search field with the values known so far, and the first empty required chip takes the keyboard.
/// Return runs the command with what the chips hold, as Return on its root row does, and the page
/// goes away first, so the run's outcome lands on the page below. Escape goes back without running.
@MainActor public final class ArgumentsPageController: PageController {
    public let command: CommandEntry
    /// The row the page shows: root search's row for the command, or one made from the command.
    public let row: Row
    /// The values the run started with, declared or not. The chips start from the declared ones.
    public let values: [String: String]
    /// How the run started. The command runs with this launch.
    public let launch: LaunchSource
    public let contentView = PageContentView()
    public let list = ResultListView()

    private let runQuery: String
    private let context: FeatureContext
    private weak var host: (any PageHost)?

    init(
        command: CommandEntry, row: Row, values: [String: String], query: String, launch: LaunchSource,
        context: FeatureContext
    ) {
        self.command = command
        self.row = row
        self.values = values
        self.launch = launch
        runQuery = query
        self.context = context
        contentView.show(list)
        list.onActivate = { [weak self] _ in
            guard let self else { return }
            host?.runPrimaryAction(for: self)
        }
    }

    /// The command's row as root search would show it, when it has none of its own.
    nonisolated static func row(for command: CommandEntry, featureName: String?) -> Row {
        Row(
            id: command.id, title: command.command.title, subtitle: command.command.subtitle ?? featureName,
            icon: command.command.icon)
    }

    public var title: String? { command.command.title }
    public var featureID: String? { command.featureID }
    public var searchPlaceholder: String { "" }
    public var query: String { "" }

    /// The index of the first required argument the chips leave empty, or nil.
    func firstMissing(in chipValues: [String]) -> Int? {
        command.command.arguments.indices.first { index in
            let argument = command.command.arguments[index]
            let value = index < chipValues.count ? chipValues[index] : ""
            return !argument.isOptional && argument.defaultValue == nil && value.isEmpty
        }
    }

    // MARK: PageController

    public func pageDidAppear(in host: any PageHost) {
        self.host = host
        render()
    }

    public func pageDidDisappear() {}
    public func pageWillClose() {}
    public func queryDidChange(_ text: String) {}
    public func moveSelection(_ move: SelectionMove) -> Bool { false }

    public var target: ActionTarget? {
        let run = ActionEntry(title: HostStrings.runCommand, kind: .command(command))
        var target = ActionTarget(
            row: row, entries: [run], featureID: command.featureID, context: context, launch: launch, query: runQuery)
        target.arguments = values
        return target
    }

    public func iconsDidChange() { render() }
    public func appearanceDidChange() { render() }

    private func render() {
        guard let host else { return }
        let mapped = host.rowMapper.listRow(row)
        list.apply(
            ListContent(
                sections: [LauncherUI.ListSection(title: nil, rows: [mapped])], rowStyle: .oneLine,
                emphasizesMatches: false))
        list.select(0, animated: false)
    }
}
