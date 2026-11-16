import AppKit
import Kit
import LauncherUI

/// What the panel shows, read the way a person would read it. The scenario runner checks these;
/// tests and benches use them too.
extension PanelController {
    /// The titles of the shown rows or cells of the top page, in order.
    public var shownTitles: [String] {
        switch top {
        case let page as RootPageController: page.list.content.sections.flatMap { $0.rows.map(\.title) }
        case let page as ListPageController: page.list.content.sections.flatMap { $0.rows.map(\.title) }
        case let page as GridPageController: page.grid.content.sections.flatMap { $0.cells.map(\.title) }
        default: []
        }
    }

    /// The selected row's or cell's title on the top page.
    public var selectedTitle: String? {
        switch top {
        case let page as RootPageController: page.selectedRow?.row.title
        case let page as ListPageController: page.selectedRow?.title
        case let page as GridPageController: page.selectedRow?.title
        default: nil
        }
    }

    /// The text of the detail shown: the detail page's, or the pane beside a list.
    public var shownDetailText: String? { shownDetailPane?.bodyText }

    /// Clicks the link with this target in the detail shown, as a person would, so it goes where
    /// a click goes. False when the detail shows no such link.
    @discardableResult public func clickDetailLink(_ target: String) -> Bool {
        shownDetailPane?.clickLink(target: target) ?? false
    }

    private var shownDetailPane: DetailPane? {
        switch top {
        case let page as DetailPageController: page.pane
        case let page as ListPageController: page.split?.detail
        default: nil
        }
    }

    /// The kind of the top page: root, list, grid, detail, form, quickLook or other.
    public var topPageKind: String {
        switch top {
        case is RootPageController: "root"
        case is ListPageController: "list"
        case is GridPageController: "grid"
        case is DetailPageController: "detail"
        case is FormPageController: "form"
        case is QuickLookPageController: "quickLook"
        default: "other"
        }
    }

    /// True when nothing loads, streams, runs or animates: the top page is not busy, no run is
    /// under way unless one waits for the user's answer to a card, the loading bar is off and the
    /// glass is not changing height.
    public var isIdle: Bool {
        !top.isBusy && !surface.isLoading && (runtime.pipeline.activeRunCount == 0 || pendingAnswer != nil)
            && !surface.isAnimatingHeight
    }
}
