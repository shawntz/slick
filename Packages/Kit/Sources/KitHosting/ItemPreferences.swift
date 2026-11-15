import Kit

/// What the user attached to items: aliases, hotkeys, favorites and off switches.
///
/// Host's feature runtime implements it and keeps it in settings. Root reads aliases and favorites
/// for ranking and the empty state. SettingsUI edits all of it. Any item can carry an alias, a hotkey
/// or a favorite: an app, a command, a quicklink, a file. Reads are in-memory lookups, cheap enough
/// for a keystroke.
@MainActor public protocol ItemPreferences: AnyObject, Sendable {
    /// Sent after any preference changed, from any writer.
    var changes: ChangeSignal { get }

    /// Aliases by item. An alias is text the user types to reach the item first, such as "ff" for
    /// a browser. Root ranks an item whose alias matches exactly or by prefix above everything else.
    var aliases: [ItemID: String] { get }

    /// Gives an item an alias, replacing its old one. Nil or empty text removes it. Two items may
    /// share an alias; both then rank first.
    func setAlias(_ alias: String?, for id: ItemID)

    /// Global hotkeys by item.
    var hotkeys: [ItemID: KeyCombo] { get }

    /// Stores an item's hotkey and binds it at once. Nil removes and unbinds it.
    ///
    /// When one of Slick's other items holds the combination, the item takes it over and the other
    /// loses it, so ask the user first with ``hotkeyConflicts(for:excluding:)``. Throws
    /// ``HotkeyError/conflict(_:)`` with the conflicts whose ``HotkeyConflict/canOverride`` is false,
    /// or ``HotkeyError/registrationFailed(code:)`` when the system refuses. Nothing is stored when it
    /// throws.
    func setHotkey(_ combo: KeyCombo?, for id: ItemID) throws

    /// Everything that already uses a combination: the system's shortcuts and Slick's own bindings,
    /// including the launcher hotkey and other items' hotkeys. Never registers anything.
    ///
    /// - Parameter id: The item being edited, whose own binding is not a conflict. Nil reports
    ///   every binding.
    func hotkeyConflicts(for combo: KeyCombo, excluding id: ItemID?) -> [HotkeyConflict]

    /// Favorite items in the user's order. Root shows them under suggestions when the query is empty.
    var favorites: [ItemID] { get }

    /// Replaces the favorites, in this order. Duplicates after the first are dropped.
    func setFavorites(_ ids: [ItemID])

    /// The user's switch for a feature, or the manifest's ``FeatureManifest/isEnabledByDefault``
    /// until the user sets one. False for an unknown feature.
    func isEnabled(feature featureID: String) -> Bool

    /// Turns a feature on or off and returns when that is done: the runtime calls
    /// ``Feature/activate()`` or ``Feature/deactivate()``, binds or unbinds the feature's hotkeys,
    /// and sends ``FeatureDirectory/changes``.
    func setEnabled(_ enabled: Bool, feature featureID: String) async

    /// The user's switch for one command, by its `cmd:` ID. True until the user turns it off.
    /// ``CommandEntry/isEnabled`` also accounts for the feature's switch.
    func isEnabled(command id: ItemID) -> Bool

    /// Turns one command on or off. A command that is off leaves root search, and its hotkey and
    /// fallback do nothing. Its alias and hotkey are kept for when it comes back on.
    func setEnabled(_ enabled: Bool, command id: ItemID)
}

extension ItemPreferences {
    /// True when the item is a favorite.
    public func isFavorite(_ id: ItemID) -> Bool {
        favorites.contains(id)
    }

    /// Adds the item to the end of the favorites, or removes it when it is one.
    public func toggleFavorite(_ id: ItemID) {
        if isFavorite(id) {
            setFavorites(favorites.filter { $0 != id })
        } else {
            setFavorites(favorites + [id])
        }
    }
}
