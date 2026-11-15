import Foundation
import Kit

/// What one menu element says about itself.
nonisolated struct MenuElementInfo<Element> {
    var title: String
    var isEnabled: Bool
    var shortcut: ShortcutAttributes
    /// The mark drawn before the title, such as a check mark. Empty for none.
    var mark: String
    /// The items of the element's submenu. Empty when it opens none.
    var children: [Element]
}

/// What a walk needs from a menu tree. The live reader answers over Accessibility, the isolated one
/// from memory, and both walk with ``MenuWalker``, so the limits and rules are the same.
///
/// `read` throws ``MenuReadError/elementFailed`` for an element the walk should leave out, and
/// ``MenuReadError/accessMissing`` or ``MenuReadError/appQuit`` to end the walk.
nonisolated protocol MenuTreeAccess {
    associatedtype Element

    /// The menus on the bar, left to right, the Apple menu first.
    func menuBarItems() throws -> [Element]

    /// One element's attributes and the items of its submenu.
    func read(_ element: Element) throws -> MenuElementInfo<Element>
}

/// Walks a menu tree depth first and lists every item that does something, in menu order.
///
/// - Separators and items with no title are left out. Menus that only open a submenu are walked
///   into, not listed.
/// - Before each element it checks, in order: should it stop, as when the launcher closed; has the
///   time limit passed; has it found the most items it may keep. Each ends the walk with what it
///   found so far.
/// - Menus deeper than the depth limit are left out, and the snapshot says so.
/// - An item under a menu that is turned off counts as turned off.
/// - An item right after another in the same menu, with the same key and Option added, is that
///   item's Option alternate, as AppKit draws alternates.
nonisolated enum MenuWalker {
    static func walk<Access: MenuTreeAccess>(
        _ access: Access, app: MenuApp, processID: Int32, limits: WalkLimits, elapsed: @escaping () -> Duration,
        shouldStop: @escaping () -> Bool
    ) throws -> MenuSnapshot {
        var walk = Walk(access: access, limits: limits, elapsed: elapsed, shouldStop: shouldStop)
        try walk.run()
        return MenuSnapshot(
            app: app, processID: processID, items: walk.items, menuTitles: walk.menuTitles, ending: walk.ending,
            leftOutDeepMenus: walk.leftOutDeepMenus)
    }

    /// How long finding an item again before a press may take. An app that answers each element
    /// slowly would otherwise hold the press, and every read after it, for as long as its menu is.
    static let findTimeLimit = Duration.seconds(3)

    /// Finds an item again by its path. Returns it with what it says about itself now, and whether
    /// it and every menu above it are turned on. Nil when the item is gone, and for a path whose
    /// item has no title: an item is pressed only after its title was checked.
    ///
    /// Throws ``MenuReadError/notAnswering`` once `elapsed` passes `limit`.
    static func find<Access: MenuTreeAccess>(
        _ path: [MenuStep], in access: Access, limit: Duration = findTimeLimit,
        elapsed: () -> Duration = { .zero }
    ) throws -> (element: Access.Element, info: MenuElementInfo<Access.Element>, isEnabled: Bool)? {
        guard let item = path.last, !item.title.isEmpty else { return nil }
        var candidates = try access.menuBarItems()
        var isEnabled = true
        for (depth, step) in path.enumerated() {
            guard let (element, info) = try pick(step, among: candidates, in: access, limit: limit, elapsed: elapsed)
            else { return nil }
            isEnabled = isEnabled && info.isEnabled
            if depth == path.count - 1 { return (element, info, isEnabled) }
            candidates = info.children
        }
        return nil
    }

    /// The candidate a step names: the one at its place when the title still matches, else the
    /// first with that title.
    private static func pick<Access: MenuTreeAccess>(
        _ step: MenuStep, among candidates: [Access.Element], in access: Access, limit: Duration,
        elapsed: () -> Duration
    ) throws -> (Access.Element, MenuElementInfo<Access.Element>)? {
        func read(_ element: Access.Element) throws -> MenuElementInfo<Access.Element>? {
            guard elapsed() < limit else { throw MenuReadError.notAnswering }
            return try readSkippingFailures(element, access)
        }
        if candidates.indices.contains(step.index), let info = try read(candidates[step.index]),
            MenuItemRef.matches(step, title: cleanTitle(info.title))
        {
            return (candidates[step.index], info)
        }
        guard !step.title.isEmpty else { return nil }
        for candidate in candidates {
            guard let info = try read(candidate) else { continue }
            if MenuItemRef.matches(step, title: cleanTitle(info.title)) { return (candidate, info) }
        }
        return nil
    }

    /// Reads one element. Nil for one that failed alone; access lost or the app gone still throw.
    static func readSkippingFailures<Access: MenuTreeAccess>(_ element: Access.Element, _ access: Access) throws
        -> MenuElementInfo<Access.Element>?
    {
        do {
            return try access.read(element)
        } catch MenuReadError.elementFailed {
            return nil
        }
    }

    /// Longest title kept. Longer titles, such as a recent document's full path, are cut.
    static let titleLimit = 300

    /// A title on one line: control characters and line breaks become spaces, and spaces at either
    /// end go. Invisible format characters stay, since emoji sequences and right-to-left text need
    /// them, but a title made only of them is empty, so no row shows a title nobody can see.
    static func cleanTitle(_ title: String) -> String {
        let kept = title.count > titleLimit ? String(title.prefix(titleLimit)) : title
        let line: String
        if kept.unicodeScalars.contains(where: breaksLine) {
            line = String(String.UnicodeScalarView(kept.unicodeScalars.map { breaksLine($0) ? " " : $0 }))
                .trimmingCharacters(in: .whitespaces)
        } else {
            line = kept.trimmingCharacters(in: .whitespaces)
        }
        return line.unicodeScalars.allSatisfy(isInvisible) ? "" : line
    }

    /// White space and format characters, such as a zero-width space or a direction mark.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .format
    }

    /// Control characters, which include tabs and line feeds, and the Unicode line and paragraph
    /// separators.
    private static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value < 0x20 || (0x7F...0x9F).contains(value) || value == 0x2028 || value == 0x2029
    }
}

/// One walk in progress.
private nonisolated struct Walk<Access: MenuTreeAccess> {
    let access: Access
    let limits: WalkLimits
    let elapsed: () -> Duration
    let shouldStop: () -> Bool

    var items: [MenuItem] = []
    var menuTitles: [Int: String] = [:]
    var ending = WalkEnding.complete
    var leftOutDeepMenus = false

    init(access: Access, limits: WalkLimits, elapsed: @escaping () -> Duration, shouldStop: @escaping () -> Bool) {
        self.access = access
        self.limits = limits
        self.elapsed = elapsed
        self.shouldStop = shouldStop
    }

    /// Ends the walk early with an ending.
    struct Stop: Error {
        var ending: WalkEnding
    }

    mutating func run() throws {
        let bar = try access.menuBarItems()
        do {
            for (place, element) in bar.enumerated() {
                try check()
                guard let info = try readLeavingOutFailures(element) else { continue }
                let title = MenuWalker.cleanTitle(info.title)
                menuTitles[place] = title
                try visit(
                    info.children, path: [MenuStep(title: title, index: place)], depth: 1, isEnabled: info.isEnabled,
                    isInAppleMenu: place == 0)
            }
        } catch let stop as Stop {
            ending = stop.ending
        }
    }

    /// Lists the items of one menu, and walks into its submenus.
    private mutating func visit(
        _ children: [Access.Element], path: [MenuStep], depth: Int, isEnabled: Bool, isInAppleMenu: Bool
    ) throws {
        // The item just before in this menu, for Option alternates.
        var previous: (index: Int, shortcut: KeyCombo)?
        for (place, element) in children.enumerated() {
            try check()
            guard let info = try readLeavingOutFailures(element) else {
                previous = nil
                continue
            }
            let title = MenuWalker.cleanTitle(info.title)
            let step = MenuStep(title: title, index: place)
            if !info.children.isEmpty {
                previous = nil
                guard depth < limits.maximumDepth else {
                    leftOutDeepMenus = true
                    continue
                }
                try visit(
                    info.children, path: path + [step], depth: depth + 1, isEnabled: isEnabled && info.isEnabled,
                    isInAppleMenu: isInAppleMenu)
                continue
            }
            guard !title.isEmpty else {
                // A separator.
                previous = nil
                continue
            }
            let shortcut = MenuShortcut.combo(info.shortcut)
            let index = items.count
            items.append(
                MenuItem(
                    path: path + [step], shortcut: shortcut, isEnabled: isEnabled && info.isEnabled, mark: info.mark,
                    isInAppleMenu: isInAppleMenu))
            if let previous, let shortcut, Self.isOptionAlternate(shortcut, of: previous.shortcut) {
                items[previous.index].optionAlternate = index
            }
            previous = shortcut.map { (index, $0) }
        }
    }

    /// True when `candidate` is `primary` with Option added.
    static func isOptionAlternate(_ candidate: KeyCombo, of primary: KeyCombo) -> Bool {
        candidate.key == primary.key && !primary.modifiers.contains(.option)
            && candidate.modifiers == primary.modifiers.union(.option)
    }

    /// Reads one element. Nil for one the walk leaves out.
    private func readLeavingOutFailures(_ element: Access.Element) throws -> MenuElementInfo<Access.Element>? {
        try MenuWalker.readSkippingFailures(element, access)
    }

    /// Stops the walk when it must: the launcher closed, the time ran out, or it found enough.
    private func check() throws {
        if shouldStop() { throw Stop(ending: .stopped) }
        if elapsed() >= limits.timeLimit { throw Stop(ending: .timedOut) }
        if items.count >= limits.maximumItems { throw Stop(ending: .tooManyItems) }
    }
}
