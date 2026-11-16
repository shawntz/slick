import Foundation
import Kit

/// The page that asks before a link runs a command. It names the command and its arguments and
/// offers Run, Always Allow and Cancel. The router selects Cancel.
///
/// Run and Always Allow do nothing until the page has shown for ``armingDelay``. The wait starts
/// when the link opens the page, and again whenever the panel opens on it or the user comes back
/// to it, so a Return pressed for something else never runs the command. A second link opens a
/// page of its own with a wait of its own. Cancel works at once.
@MainActor final class LinkConsentSource: ListSource, PageEvents {
    /// How long the page shows before Run and Always Allow work.
    static let armingDelay: Duration = .seconds(1)
    static let runID = ItemID("app-link", "run")
    static let alwaysID = ItemID("app-link", "always")
    static let cancelID = ItemID("app-link", "cancel")

    /// What the user chose.
    enum Choice: Sendable {
        case run, always, cancel
    }

    private let commandTitle: String
    private let rows: [Row]
    private let clock: any ClockService
    private let choose: @MainActor @Sendable (Choice) -> Void
    /// When the current wait started.
    private(set) var shownAt: Date

    /// - Parameters:
    ///   - commandTitle: The title of the command the link asks to run.
    ///   - arguments: The arguments the link passes, shown under Run.
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
        rows = [
            Row(
                id: Self.runID, title: AppStrings.linkRunOnce(commandTitle),
                subtitle: AppStrings.linkArguments(arguments), icon: .symbol("play.fill"), memory: .never),
            Row(
                id: Self.alwaysID, title: AppStrings.linkAlwaysAllow, subtitle: alwaysDetail,
                icon: .symbol("checkmark.shield"), memory: .never),
            Row(id: Self.cancelID, title: AppStrings.linkCancel, icon: .symbol("xmark"), memory: .never),
        ]
    }

    /// True once the page has shown for ``armingDelay`` since the wait last started.
    var isArmed: Bool {
        let parts = Self.armingDelay.components
        let delay = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return clock.now.timeIntervalSince(shownAt) >= delay
    }

    func load(_ request: ListRequest) async throws -> ListResult {
        ListResult(sections: [ListSection(AppStrings.linkSection, id: "link", rows: rows)])
    }

    func actions(for row: Row) -> [Action] {
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
