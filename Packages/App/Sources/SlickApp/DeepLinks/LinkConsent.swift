import Foundation
import Host
import Kit

/// The page that asks before a link runs a command. It names the command and offers Run, Always
/// Allow and Cancel. The router selects Cancel.
///
/// Each argument the link passes has a row of its own, and a detail pane beside the rows shows
/// every argument in full whatever row is selected, so nothing the command will get is cut from
/// view. A page for a link without arguments has no detail pane.
///
/// Run and Always Allow do nothing until the page has shown for ``armingDelay``. The wait starts
/// when the link opens the page, and again whenever the panel opens on it or the user comes back
/// to it, so a Return pressed for something else never runs the command. A second link opens a
/// page of its own with a wait of its own. Cancel works at once. Typing filters nothing, and the
/// panel runs no row of this page for Command-1 to 9, so only a selection the user moved runs it.
@MainActor final class LinkConsentSource: ListSource, PageEvents {
    /// How long the page shows before Run and Always Allow work: the same wait as a destructive
    /// question in a session a link opened.
    static let armingDelay: Duration = PanelController.linkConfirmationHold
    static let runID = ItemID("app-link", "run")
    static let alwaysID = ItemID("app-link", "always")
    static let cancelID = ItemID("app-link", "cancel")

    /// The row of the argument with this name.
    static func argumentID(_ name: String) -> ItemID {
        ItemID("app-link", "argument." + name)
    }

    /// What the user chose.
    enum Choice: Sendable {
        case run, always, cancel
    }

    private let commandTitle: String
    private let sections: [ListSection]
    private let argumentIDs: Set<ItemID>
    /// Every argument in full, for the detail pane. Nil when the link passes none.
    let shownInFull: Detail?
    private let clock: any ClockService
    private let choose: @MainActor @Sendable (Choice) -> Void
    /// When the current wait started.
    private(set) var shownAt: Date

    /// - Parameters:
    ///   - commandTitle: The title of the command the link asks to run.
    ///   - arguments: The arguments the link passes, each on a row of its own.
    ///   - alwaysDetail: What Always Allow will allow, shown under it.
    ///   - clock: What the wait is counted on.
    ///   - choose: Runs after the user chose Run or Always Allow and the wait is over, or chose Cancel.
    init(
        commandTitle: String, arguments: [String: String], alwaysDetail: String, clock: any ClockService,
        choose: @escaping @MainActor @Sendable (Choice) -> Void
    ) {
        self.commandTitle = commandTitle
        self.clock = clock
        self.choose = choose
        shownAt = clock.now
        let choices = [
            Row(
                id: Self.runID, title: AppStrings.linkRunOnce(commandTitle),
                subtitle: AppStrings.linkArgumentCount(arguments.count), icon: .symbol("play.fill"), memory: .never),
            Row(
                id: Self.alwaysID, title: AppStrings.linkAlwaysAllow, subtitle: alwaysDetail,
                icon: .symbol("checkmark.shield"), memory: .never),
            Row(id: Self.cancelID, title: AppStrings.linkCancel, icon: .symbol("xmark"), memory: .never),
        ]
        let argumentRows = arguments.keys.sorted().map { name in
            Row(
                id: Self.argumentID(name), title: name, subtitle: AppStrings.linkArgumentValue(arguments[name] ?? ""),
                icon: .symbol("text.cursor"), memory: .never)
        }
        var sections = [ListSection(AppStrings.linkSection, id: "link", rows: choices)]
        if !argumentRows.isEmpty {
            sections.append(ListSection(AppStrings.linkArgumentsSection, id: "arguments", rows: argumentRows))
        }
        self.sections = sections
        argumentIDs = Set(argumentRows.map(\.id))
        shownInFull =
            arguments.isEmpty
            ? nil
            : Detail(.text(AppStrings.linkArgumentsInFull(commandTitle, arguments: arguments), monospaced: false))
    }

    /// True once the page has shown for ``armingDelay`` since the wait last started.
    var isArmed: Bool {
        let parts = Self.armingDelay.components
        let delay = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return clock.now.timeIntervalSince(shownAt) >= delay
    }

    /// The page filters nothing. A link can arrive while the user types in the launcher, and the
    /// rest of their word must not hide Cancel and select Run or Always Allow, so every row stays
    /// and Cancel stays selected whatever is typed.
    var filtering: ListFiltering { .custom(debounce: .zero) }

    /// The same rows for every query.
    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: sections)
    }

    /// The same for every row: each argument in full.
    func detail(for row: Row) async throws -> Detail? {
        shownInFull
    }

    func actions(for row: Row) -> [Action] {
        // An argument row only shows what the command will get.
        guard !argumentIDs.contains(row.id) else { return [] }
        let choice: Choice
        let label: String
        switch row.id {
        case Self.runID:
            choice = .run
            label = AppStrings.linkRunOnce(commandTitle)
        case Self.alwaysID:
            choice = .always
            label = AppStrings.linkAlwaysAllow
        default:
            choice = .cancel
            label = AppStrings.linkCancel
        }
        return [
            Action(label, id: "link." + row.id.key) { [weak self] context in
                guard let self else { return .keepOpen }
                if choice == .cancel {
                    choose(.cancel)
                    return .popToRoot
                }
                guard isArmed else {
                    context.showToast(.failure(AppStrings.linkWait, message: AppStrings.linkWaitMessage))
                    return .keepOpen
                }
                choose(choice)
                return .keepOpen
            }
        ]
    }

    func pageWillShowAgain(_ reason: PageShowReason) {
        shownAt = clock.now
    }
}
