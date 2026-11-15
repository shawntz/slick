/// Anything that makes rows: it also makes their actions, on demand.
///
/// The host calls ``actions(for:)`` when the selection settles and when the action panel opens. It
/// runs on the main thread inside an interaction, so it must be cheap: build the actions from the
/// row's ``Row/id`` and ``Row/payload`` and capture what they need; do no I/O. A ``Payload`` made
/// from the item itself hands it back by a cast.
///
/// Return runs the first action. Command-Return runs the action whose shortcut is
/// ``KeyCombo/secondaryAction``, or else the second action unless it declares a shortcut of its own
/// (see `[Action].secondary`).
///
/// Root remembers rows the user runs and may hand a row back after a relaunch, rebuilt from a
/// snapshot. ``actions(for:)`` must work from such a row alone.
@MainActor public protocol RowActionProvider: AnyObject, Sendable {
    func actions(for row: Row) -> [Action]
}

/// A source whose rows can change while they are shown: a list page, a catalog source or a
/// suggestion trigger. The host loads it again when ``changes`` fires or a setting in
/// ``reloadsOnSettings`` changes, while what it feeds is visible.
///
/// The defaults live here, once, so one object can be several kinds of source.
@MainActor public protocol RowSource: RowActionProvider {
    /// Fires when the rows changed, such as a new clipboard entry. Send it from any thread. Default
    /// nil.
    var changes: ChangeSignal? { get }

    /// Settings the rows depend on, such as a sort order, so the source needs no task of its own to
    /// watch them. Default none.
    var reloadsOnSettings: [AnySettingKey] { get }
}

extension RowSource {
    public var changes: ChangeSignal? { nil }
    public var reloadsOnSettings: [AnySettingKey] { [] }
}

/// A row source whose items can disappear behind its back, such as files deleted in Finder. Root
/// asks it, in batches and off the keystroke path, which of its remembered rows still exist, and
/// forgets the rest so dead rows stop ranking.
@MainActor public protocol RememberedRowValidator: RowActionProvider {
    /// The IDs among `ids` whose items still exist.
    func existingItems(among ids: [ItemID]) async -> Set<ItemID>
}
