import AppKit
import Kit
import KitHosting
import LauncherUI

/// One page on the panel's navigation stack: root search at the bottom, then whatever commands
/// pushed.
///
/// The panel controller owns the search field, the action bar, the action panel and the keyboard.
/// A page owns its content view and its selection, and answers what Return, Command-Return and
/// Command-K act on through ``target``. To add a kind of page, conform a class to this protocol,
/// return it from ``PanelController/makePage(_:origin:)`` for its `Page` case, and draw into a
/// ``PageContentView`` so the panel keeps its height rules.
///
/// Call order: ``pageDidAppear(in:)`` when the page reaches the top, by a push or because the page
/// above it was popped; ``pageDidDisappear()`` when another page covers it or it is popped;
/// ``pageWillClose()`` once, when it is popped for good. ``queryDidChange(_:)`` runs inside the
/// keystroke: do only cheap synchronous work there and start anything slow in a task.
///
/// Pages do no work while the panel is hidden. ``panelDidHide()`` tells the page on top that the
/// panel closed: it stops listening and drawing, and remembers a change signal that arrives then.
/// ``panelDidClose()`` then tells every page in the stack, top first. ``panelDidShow()`` comes soon
/// after the panel opens again, off the summon path: the page reloads once if anything changed. A
/// page that returns to the top by a pop while the panel is hidden hears ``panelDidHide()`` before
/// ``pageDidAppear(in:)``, so it does nothing until the panel shows.
@MainActor public protocol PageController: AnyObject {
    /// The page's name for the breadcrumb and the action bar. Nil for root search.
    var title: String? { get }
    /// The feature that pushed the page. The panel closes the page when that feature is switched
    /// off. Default nil, for the host's own pages.
    var featureID: String? { get }
    /// The search field's placeholder.
    var searchPlaceholder: String { get }
    /// The search text the page opens with.
    var initialQuery: String { get }
    /// The search text now, put back in the field when the page returns to the top.
    var query: String { get }
    /// The view in the content area.
    var contentView: PageContentView { get }
    /// The dropdown at the end of the search field, or nil.
    var filter: QueryFilter? { get }

    func pageDidAppear(in host: any PageHost)
    func pageDidDisappear()
    func pageWillClose()

    /// The search text changed.
    func queryDidChange(_ text: String)
    /// An option of ``filter`` was chosen.
    func filterDidChange(_ optionID: String)
    /// Moves the selection. Returns false when there is nothing to move.
    func moveSelection(_ move: SelectionMove) -> Bool
    /// What the keys act on now: the selected row and its actions, or the empty state's actions.
    var target: ActionTarget? { get }
    /// The Nth row's target, for Command-1 to 9, without moving the selection.
    func target(at index: Int) -> ActionTarget?
    /// Loads again, as after ``ActionContext/reload()``.
    func reload()
    /// Icons that were not ready may be ready now. Look up the visible rows again.
    func iconsDidChange()
    /// Offers a key to the page before the panel's keyboard model sees it. Return true to claim it,
    /// as a grid does for Left and Right. Default false.
    func handle(_ command: QueryCommand) -> Bool
    /// The rows or cells in view changed, as LauncherUI reports for the wheel, the trackpad and a
    /// selection scrolled into view: load what came into view, such as the next page or root
    /// highlights. Default nothing.
    func contentDidScroll()
    /// The panel switched between light and dark: draw adaptive icons again. Default nothing.
    func appearanceDidChange()
    /// True while the page loads, streams or submits, for the scenario runner's idle wait.
    /// Default false.
    var isBusy: Bool { get }
    /// What the action bar names in place of the page's title, such as the selected cell of a
    /// grid that hides titles. Default nil, for the page's title.
    var selectionTitle: String? { get }
    /// False while Return must not run the primary entry, as on a detail page that takes follow-ups
    /// while its answer streams. The action bar then names no primary entry. Default true.
    var returnRunsPrimary: Bool { get }
    /// The panel closed with this page on top. Stop listening, refreshing and drawing; remember a
    /// change that arrives from now on. Default nothing.
    func panelDidHide()
    /// The panel opened again with this page on top. Reload once if a change arrived while it was
    /// hidden. Runs on the turn after the summon, never on the summon path. Default nothing.
    func panelDidShow()
    /// The panel closed while this page was anywhere in the stack, top page first. Pass it on to a
    /// source that adopts Kit's `PageEvents`. Default nothing.
    func panelDidClose()
}

extension PageController {
    public var filter: QueryFilter? { nil }
    public var featureID: String? { nil }
    public var initialQuery: String { "" }
    public func filterDidChange(_ optionID: String) {}
    public func target(at index: Int) -> ActionTarget? { nil }
    public func reload() {}
    public func iconsDidChange() {}
    public func handle(_ command: QueryCommand) -> Bool { false }
    public func contentDidScroll() {}
    public func appearanceDidChange() {}
    public var isBusy: Bool { false }
    public var selectionTitle: String? { nil }
    public var returnRunsPrimary: Bool { true }
    public func panelDidHide() {}
    public func panelDidShow() {}
    public func panelDidClose() {}
}

/// A selection move the keyboard asks for.
public enum SelectionMove: Sendable, Equatable {
    case up, down, previousSection, nextSection
}

/// What the panel offers pages.
@MainActor public protocol PageHost: AnyObject {
    var runtime: FeatureRuntime { get }
    /// Kit rows as LauncherUI rows, with icons.
    var rowMapper: RowMapper { get }
    /// The resolved theme the panel draws with now.
    var resolvedTheme: ResolvedTheme { get }
    /// The page's selection or rows changed: refresh the action bar.
    func pageSelectionDidChange(_ page: any PageController)
    /// Shows or hides the loading bar for the page.
    func page(_ page: any PageController, isLoading: Bool)
    /// The page's dropdown changed.
    func pageFilterDidChange(_ page: any PageController)
    /// Shows a failure toast for an error a source threw. `CancellationError` shows nothing.
    func pageDidFail(_ page: any PageController, error: any Error)
    /// The panel's latency probe: wrap each interaction in one interval.
    var probe: LatencyProbe { get }
    /// What the user attached to items, such as remembered dropdown options.
    var preferences: HostPreferences { get }
    /// Replaces the search field's text without running the page's query handling, as when a
    /// detail page clears its follow-up field.
    func replaceQueryText(_ text: String)
    /// Goes back from this page, if it is on top, as Escape on an empty query does.
    func popPage(_ page: any PageController)
    /// Opens the action panel for the page's target.
    func openActions(for page: any PageController)
    /// Runs the primary entry of the page's target, as Return does, such as after a double click.
    func runPrimaryAction(for page: any PageController)
    /// Wrap calls into Root and LauncherUI in ``WorkMeter/measure(_:)``, so benches can tell the
    /// host's own work from theirs.
    var workMeter: WorkMeter { get }
}

/// What Return, Command-Return, Command-K and Command-1 to 9 act on.
public struct ActionTarget {
    /// The row, or nil for an empty state's actions.
    public var row: Row?
    /// The row's own entries, primary first: its actions, or Run and the command's row actions.
    public var entries: [ActionEntry]
    /// The feature the row belongs to.
    public var featureID: String
    public var context: FeatureContext
    /// How runs from here start.
    public var launch: LaunchSource
    /// The search text when the run starts.
    public var query: String
    /// True for a root search row, which gets the host's own entries and is reported to Root.
    public var isRoot: Bool
    /// Where the action panel puts universal actions among ``entries``: after Run for a command
    /// row, so the command's row actions follow them; after everything otherwise.
    public var universalInsertIndex: Int
    /// Entries only the action panel shows, after everything else, such as a notice's button.
    /// They never become the primary or the secondary entry.
    public var panelExtras: [ActionEntry] = []
    /// Argument values a run from here starts with, declared or not, before what the argument
    /// chips hold. Empty for most targets.
    public var arguments: [String: String] = [:]
    /// What the target stands for: the row's ``Row/represents``, or for a detail page its
    /// ``Detail/represents``. The action panel offers universal actions for it, and for text Show
    /// in Large Type.
    public var represents: Selection?

    public init(
        row: Row?, entries: [ActionEntry], featureID: String, context: FeatureContext, launch: LaunchSource,
        query: String, isRoot: Bool = false
    ) {
        self.row = row
        self.entries = entries
        self.featureID = featureID
        self.context = context
        self.launch = launch
        self.query = query
        self.isRoot = isRoot
        universalInsertIndex = entries.count
        represents = row?.represents
    }

    /// The text Show in Large Type shows for this target, or nil when it stands for no text.
    public var largeTypeText: String? {
        guard case .text(let text) = represents, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// The entry Return runs.
    public var primary: ActionEntry? { entries.first }

    /// The entry Command-Return runs, by the rule in `[Action].secondary`: the one whose shortcut is
    /// Command-Return, else the second unless it declares a shortcut of its own.
    public var secondary: ActionEntry? {
        if let declared = entries.first(where: { $0.shortcut == .secondaryAction }) { return declared }
        guard entries.count > 1, entries[1].shortcut == nil else { return nil }
        return entries[1]
    }
}

/// One entry in the action panel.
public struct ActionEntry {
    /// What choosing it does.
    public enum Kind {
        /// A feature's action, run by the pipeline with this feature's context.
        case action(Action, featureID: String, context: FeatureContext)
        /// A command, run by the pipeline with its requires, confirmation and policy.
        case command(CommandEntry)
        /// One of the host's own entries for a root row.
        case host(HostEntry)
        /// The button of the toast showing now.
        case toast(ToastAction, RunOrigin)
        /// Something the page does itself, such as submitting a form or picking a share service.
        case custom(@MainActor () -> Void)
    }

    public var title: String
    public var icon: Icon?
    public var shortcut: KeyCombo?
    public var isDestructive: Bool
    public var section: String?
    /// The search text the run gets when it is not the target's, as for a universal action, whose
    /// query is what the row stands for, as text.
    public var query: String?
    public var kind: Kind

    public init(
        title: String, icon: Icon? = nil, shortcut: KeyCombo? = nil, isDestructive: Bool = false,
        section: String? = nil, query: String? = nil, kind: Kind
    ) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.section = section
        self.query = query
        self.kind = kind
    }

    /// An entry for a feature's action, with its title, icon, shortcut and section.
    public init(_ action: Action, featureID: String, context: FeatureContext, section: String? = nil) {
        self.init(
            title: action.title, icon: action.icon, shortcut: action.shortcut,
            isDestructive: action.style == .destructive, section: section ?? action.section,
            kind: .action(action, featureID: featureID, context: context))
    }
}

/// The host's own entries for root rows.
public enum HostEntry: Equatable {
    case addFavorite, removeFavorite, setAlias, setHotkey, resetRanking, disableCommand
}
