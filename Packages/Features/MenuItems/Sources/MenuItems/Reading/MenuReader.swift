import Foundation
import Kit

/// Reads another app's menu bar and presses its items. It lives in this package because no other
/// feature needs it.
///
/// Every requirement that does work is `@concurrent`, so it runs off the main thread whoever calls
/// it. The live reader uses Accessibility and needs the Accessibility permission. The isolated one
/// serves menu trees held in memory and touches nothing.
nonisolated protocol MenuReader: Sendable {
    /// Walks the app's menu bar within the limits and returns every item found. A walk that hits a
    /// limit or is cancelled, as when the panel closes, returns what it read so far, with an ending
    /// that says why.
    @concurrent func readMenus(of app: MenuApp, limits: WalkLimits) async throws -> MenuSnapshot

    /// Lets the app come back to the front, finds the item again and presses it.
    @concurrent func press(_ item: MenuItemRef) async throws
}

/// Why the menus could not be read or an item could not be pressed.
nonisolated enum MenuReadError: Error, Hashable, Sendable {
    /// Accessibility is not granted.
    case accessMissing
    /// No running app has this bundle ID.
    case appNotRunning
    /// The app quit while its menus were read or before an item was pressed.
    case appQuit
    /// The app shows no menu bar, as an app that lives in the menu bar's right side does.
    case noMenuBar
    /// The app did not answer in time.
    case notAnswering
    /// The item is gone, as when the app rebuilt the menu since it was read.
    case itemGone
    /// The app turned the item off since it was read.
    case itemDisabled
    /// One element could not be read. The walk leaves it out and goes on.
    case elementFailed
}

/// The menu reader for each kind of run. Scenarios, self-tests and benchmarks get menus in memory,
/// so they never read or press anything in a real app.
nonisolated enum MenuReaderKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any MenuReader { AccessibilityMenus() }
    static func isolated(_ context: FeatureContext) -> any MenuReader { SimulatedMenus.sample() }
}
