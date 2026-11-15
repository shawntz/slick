/// What a page's source can learn about its page besides loads: that the page shows again, and that
/// the panel closed.
///
/// Adopt it on a ``ListSource`` or a ``DetailSource`` whose content goes stale while nobody looks,
/// such as the menus of the app in front, which may be another app by the next summon. The host
/// calls the methods on the main actor, outside the summon path, and never inside a keystroke, so
/// keep them short: set a flag, cancel a task, send the page's ``ChangeSignal``.
///
/// ```swift
/// final class MenuList: ListSource, PageEvents {
///     let signal = ChangeSignal()
///     var changes: ChangeSignal? { signal }
///     func panelDidClose() { reading?.cancel() }
///     func pageWillShowAgain(_ reason: PageShowReason) { signal.send() }  // read the menus again
/// }
/// ```
@MainActor public protocol PageEvents: AnyObject {
    /// The page is about to show again: the panel opened with it on top after it was closed, or
    /// the user went back to it from a page above. Not called when the page first opens.
    ///
    /// The host calls it before it decides whether to load the page again. A source that sends its
    /// change signal here gets one reload, as for a change that arrived while the page was hidden.
    /// Default nothing.
    func pageWillShowAgain(_ reason: PageShowReason)

    /// The panel closed while the page was anywhere in the navigation stack. Called once per close,
    /// for the top page first. The page stays in the stack, and is closed for good only when the
    /// stack returns to root search. Stop work that only makes sense while the user looks, such as
    /// a read of another app's menus. Default nothing.
    func panelDidClose()
}

extension PageEvents {
    public func pageWillShowAgain(_ reason: PageShowReason) {}
    public func panelDidClose() {}
}

/// Why a page shows again.
public enum PageShowReason: Hashable, Sendable {
    /// The panel opened again with the page on top.
    case panelOpened
    /// The user went back to the page from a page above it.
    case returned
}
