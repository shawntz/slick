import Kit

/// The feature's settings, stored as `menu-items.<name>`. `nonisolated`, so row building off the
/// main thread can read them.
nonisolated enum MenuItemsSettings {
    /// True lists items the app has turned off, marked as unavailable.
    static let showsDisabledItems = SettingKey("showsDisabledItems", default: false)
    /// True lists the items of the Apple menu, such as Restart and Log Out.
    static let showsAppleMenu = SettingKey("showsAppleMenu", default: false)
    /// Bundle IDs of apps whose menus are never read.
    static let leftOutApps = SettingKey("leftOutApps", default: [String]())

    /// The keys whose change changes the rows of an open list.
    static let listKeys: [AnySettingKey] = [showsDisabledItems.erased, showsAppleMenu.erased, leftOutApps.erased]

    /// What decides which items show, read once per load.
    static func options(_ settings: FeatureSettings) -> MenuOptions {
        MenuOptions(showsDisabledItems: settings[showsDisabledItems], showsAppleMenu: settings[showsAppleMenu])
    }
}

/// Which items a list shows.
nonisolated struct MenuOptions: Hashable, Sendable {
    var showsDisabledItems = false
    var showsAppleMenu = false

    func shows(_ item: MenuItem) -> Bool {
        (showsDisabledItems || item.isEnabled) && (showsAppleMenu || !item.isInAppleMenu)
    }
}
