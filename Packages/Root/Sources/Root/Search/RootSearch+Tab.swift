import Kit
import KitHosting

extension RootSearch {
    /// The command Tab runs with the typed text: the one chosen in ``HostSettings/tabCommand``, while
    /// it is on and declares ``Command/takesRootQueryOnTab``. Nil when none is chosen or it cannot run.
    /// Every typed snapshot carries it as ``RootSnapshot/tabCommand``.
    public var tabCommand: ItemID? {
        guard let id = settingsCache.tabCommandID, plan.tabCommands.contains(id) else { return nil }
        return id
    }
}
