/// A page's source that can be busy with work of its own between loads, such as a read of another
/// app's menus that ends with a change signal.
///
/// Adopt it on a ``ListSource`` or a ``DetailSource`` whose page says it is waiting, such as
/// "Reading Menus", while no load runs. The host counts the page as busy while ``isBusy`` is true,
/// as it does while the page loads, so a scenario's idle wait, the self-test and benchmarks wait
/// for the work to end. The live launcher never waits for it. The host reads it often, so keep it
/// a stored flag or a check of a task.
///
/// ```swift
/// final class MenuList: ListSource, BusySource {
///     private var read: Task<Void, Never>?
///     var isBusy: Bool { read != nil }
/// }
/// ```
@MainActor public protocol BusySource: AnyObject {
    /// True while the source works on something its page will show when the work ends.
    var isBusy: Bool { get }
}
