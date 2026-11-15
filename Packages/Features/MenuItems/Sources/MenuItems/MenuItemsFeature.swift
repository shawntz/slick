import Foundation
import Kit

/// Menu items: search the menu bar of the app that was in front when the launcher opened, and run
/// a menu item from the keyboard.
///
/// - One command, Search Menu Items, pushes a list of every item with its path and shortcut. Turned
///   off items and the Apple menu are left out unless settings say otherwise.
/// - Return closes the launcher, lets the app come back to the front, then presses the item.
/// - Menus are read through ``MenuReader``: Accessibility in the app, menus in memory in scenarios,
///   self-tests and tests. Reads run off the main thread with time, depth and size limits, and stop
///   when the launcher closes.
/// - What was read is kept per app for the session, so the next search of the same app shows at
///   once while a fresh read runs in the background.
///
/// Activation does nothing: no read, no observer, no permission check. The first read happens when
/// the user runs the command.
public final class MenuItemsFeature: Feature {
    public static let manifest = FeatureManifest(
        id: "menu-items", name: Strings.featureName, icon: .symbol("filemenu.and.selection"),
        summary: Strings.summary,
        permissions: [PermissionNeed(.accessibility, reason: Strings.accessibilityReason)])

    static let searchCommandID = "search"

    let context: FeatureContext
    let reader: any MenuReader
    let cache = MenuCache()
    /// How far a read may go. Tests shorten it.
    var limits = WalkLimits.standard
    /// The list open now, so turning the feature off can stop its read.
    private(set) weak var currentList: MenuItemList?

    /// Does no I/O. The live reader touches nothing until the command runs.
    public init(context: FeatureContext) {
        self.context = context
        reader = context.service(MenuReaderKey.self)
    }

    public var commands: [Command] {
        [
            Command(
                id: Self.searchCommandID, title: Strings.searchMenuItems, icon: .symbol("filemenu.and.selection"),
                keywords: Strings.keywords, requires: [.accessibility]
            ) { context in
                self.search(context)
            }
        ]
    }

    public var settingsPane: SettingsPane? {
        SettingsPane([
            SettingsSection(
                Strings.showSection,
                items: [
                    .toggle(
                        Strings.showsDisabledItems, key: MenuItemsSettings.showsDisabledItems,
                        info: Strings.showsDisabledItemsInfo),
                    .toggle(
                        Strings.showsAppleMenu, key: MenuItemsSettings.showsAppleMenu, info: Strings.showsAppleMenuInfo),
                ]),
            SettingsSection(
                Strings.appsSection,
                items: [
                    .list(
                        Strings.leftOutApps, key: MenuItemsSettings.leftOutApps, itemKind: .application,
                        info: Strings.leftOutAppsInfo)
                ]),
            SettingsSection(Strings.accessSection, items: [.permission(.accessibility, info: Strings.accessInfo)]),
            SettingsSection(Strings.privacySection, items: [.note(Strings.storageNote), .note(Strings.networkNote)]),
        ])
    }

    public func deactivate() async {
        currentList?.stop()
        currentList = nil
        cache.removeAll()
    }

    // MARK: - Search Menu Items

    /// Pushes the list for the app that was in front, or says why there is none.
    func search(_ context: ActionContext) -> ActionOutcome {
        let leftOut = context.settings[MenuItemsSettings.leftOutApps]
        let target = MenuTarget.resolve(context.workspace.frontmostApplication(), leftOut: leftOut)
        switch target {
        case .none:
            context.showToast(.failure(Strings.noAppTitle, message: Strings.noAppMessage))
            return .keepOpen
        case .leftOut(let app):
            cache.remove(app.bundleID)
            context.showToast(.failure(Strings.leftOutTitle(app.name), message: Strings.leftOutMessage))
            return .keepOpen
        case .app(let app):
            currentList?.stop()
            let list = MenuItemList(target: target, context: self.context, reader: reader, cache: cache, limits: limits)
            currentList = list
            return .push(
                .list(ListPage(list, title: app.name, searchPlaceholder: Strings.placeholder(app.name))))
        }
    }
}
