import AppKit

/// A view that fills the content area between the query row and the action bar.
///
/// The result list is one. Grids, detail panes and forms are others: each conforms, and
/// `LauncherSurface` hosts whichever is current. The surface gives the view the full panel width
/// and the theme's maximum content height, and sizes the glass from `preferredContentHeight`.
public protocol LauncherContentView: NSView {
    /// The height the content wants now, at most `limit`. Zero means the content is empty.
    func preferredContentHeight(limit: CGFloat) -> CGFloat
    /// Restyles the view for a resolved theme.
    func apply(_ theme: ResolvedTheme)
    /// The panel's selection lens, for content that shows a selection. Nil when detached.
    var selectionLens: SelectionLens? { get set }
    /// Set by the surface. Call it when `preferredContentHeight` changes so the glass follows.
    var contentHeightDidChange: (() -> Void)? { get set }
}
