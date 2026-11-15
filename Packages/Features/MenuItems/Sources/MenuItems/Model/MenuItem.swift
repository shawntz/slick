import Foundation
import Kit

/// The app whose menus are read: the one that was in front when the launcher opened.
nonisolated struct MenuApp: Hashable, Sendable, Codable {
    var bundleID: String
    var name: String
}

/// One step on the way from the menu bar to an item: a title and the place among its siblings,
/// counting separators. The place finds the item again quickly; the title checks it is the same one.
nonisolated struct MenuStep: Hashable, Sendable, Codable {
    var title: String
    var index: Int
}

/// Names one menu item for as long as its app runs, so it can be pressed later.
nonisolated struct MenuItemRef: Hashable, Sendable, Codable {
    var bundleID: String
    var processID: Int32
    /// From the menu bar title down to the item itself.
    var path: [MenuStep]

    /// Longest title a reference keeps per step. A longer one is matched by its start.
    static let titleLimit = 80

    init(bundleID: String, processID: Int32, path: [MenuStep]) {
        self.bundleID = bundleID
        self.processID = processID
        self.path = path.map { MenuStep(title: String($0.title.prefix(Self.titleLimit)), index: $0.index) }
    }

    /// The row key: the bundle ID, then the place of each step, as in `com.example.editor/2.5.1`.
    var key: String {
        bundleID + "/" + path.map { String($0.index) }.joined(separator: ".")
    }

    /// Parses a row key. The key holds places, not titles, so `title` names the item itself: a press
    /// then checks the item at that place still has it. Nil when any part of the key is not a place,
    /// or the title is empty.
    init?(key: String, title: String) {
        guard let slash = key.lastIndex(of: "/"), slash != key.startIndex else { return nil }
        let parts = key[key.index(after: slash)...].split(separator: ".", omittingEmptySubsequences: false)
        let places = parts.compactMap { part in part.allSatisfy { ("0"..."9").contains($0) } ? Int(part) : nil }
        guard !places.isEmpty, places.count == parts.count, !title.isEmpty else { return nil }
        var path = places.map { MenuStep(title: "", index: $0) }
        path[path.count - 1].title = title
        self.init(bundleID: String(key[..<slash]), processID: 0, path: path)
    }

    /// True when a title read from the app names the same step: equal, or equal in its first
    /// ``titleLimit`` characters. An empty step title matches any, which only a menu above the item
    /// may have: ``MenuWalker/find(_:in:limit:elapsed:)`` refuses an item step without a title.
    static func matches(_ step: MenuStep, title: String) -> Bool {
        step.title.isEmpty || step.title == title || step.title == String(title.prefix(titleLimit))
    }
}

/// One menu item that does something: a leaf of the menu tree. Menus that only open a submenu are
/// not items, and neither are separators.
nonisolated struct MenuItem: Hashable, Sendable {
    /// From the menu bar title down to the item itself.
    var path: [MenuStep]
    var shortcut: KeyCombo?
    /// False when the item, or a menu above it, was turned off when it was read.
    var isEnabled: Bool
    /// The mark the app draws before the title, such as a check mark. Empty for none.
    var mark: String
    /// True for items under the first menu of the bar, the Apple menu.
    var isInAppleMenu: Bool
    /// The item that takes this one's place while Option is held, by its position in the walk's
    /// list. Set when the next item in the same menu has the same key with Option added.
    var optionAlternate: Int?

    var title: String { path.last?.title ?? "" }

    /// The titles of the menus above the item, from the menu bar down.
    var menus: [String] { path.dropLast().map(\.title) }

    func ref(bundleID: String, processID: Int32) -> MenuItemRef {
        MenuItemRef(bundleID: bundleID, processID: processID, path: path)
    }
}

/// How a walk of the menu bar ended.
nonisolated enum WalkEnding: Hashable, Sendable {
    /// Every menu was read, apart from menus deeper than the depth limit.
    case complete
    /// The time limit passed. The items read before it are kept.
    case timedOut
    /// The item limit was reached. The items read before it are kept.
    case tooManyItems
    /// The launcher closed or the read was cancelled. The items read before it are kept.
    case stopped
}

/// What one walk of an app's menu bar found.
nonisolated struct MenuSnapshot: Hashable, Sendable {
    var app: MenuApp
    var processID: Int32
    /// Every item, in menu order: left to right across the bar, top to bottom in each menu.
    var items: [MenuItem]
    /// The titles of the menus on the bar, left to right, by their place.
    var menuTitles: [Int: String]
    var ending: WalkEnding
    /// True when a menu was left out because it lies deeper than the depth limit.
    var leftOutDeepMenus: Bool

    /// True when the walk read everything it was allowed to.
    var isComplete: Bool { ending == .complete }
}

/// How far a walk may go. Some apps have thousands of items and some answer slowly.
nonisolated struct WalkLimits: Hashable, Sendable {
    /// The walk stops after this long and keeps what it read.
    var timeLimit: Duration
    /// Menus deeper than this below the menu bar are left out. The bar's own menus are depth 1.
    var maximumDepth: Int
    /// The walk stops after this many items.
    var maximumItems: Int
    /// How long one Accessibility call may wait for the app, in seconds. Live reader only.
    var messagingTimeout: Float

    init(
        timeLimit: Duration = .seconds(3), maximumDepth: Int = 8, maximumItems: Int = 20_000,
        messagingTimeout: Float = 0.25
    ) {
        self.timeLimit = timeLimit
        self.maximumDepth = maximumDepth
        self.maximumItems = maximumItems
        self.messagingTimeout = messagingTimeout
    }

    static let standard = WalkLimits()
}
