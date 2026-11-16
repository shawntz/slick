import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// The live menu reader, over the Accessibility API.
///
/// Every Accessibility call runs on one serial background queue, so none is ever on the main
/// thread and a press never interleaves with a walk. Each call waits at most
/// ``WalkLimits/messagingTimeout`` for the app, and a walk stops at its time limit, at its depth and
/// item limits, when its task is cancelled, and when the launcher closes.
///
/// It reads only the menu bar of the app it is given. It never opens a menu on screen, so menus an
/// app fills only while they are open show what they held when last opened.
///
/// It needs the Accessibility permission. Nothing here asks for it: a missing grant surfaces as
/// ``MenuReadError/accessMissing`` and the feature shows the host's grant card. None of these calls
/// shows a prompt.
///
/// This class reads another app and presses its menu items. Tests use ``SimulatedMenus``; nothing
/// in the test target runs this class.
nonisolated final class AccessibilityMenus: MenuReader {
    private let queue = DispatchQueue(label: "menu-items.accessibility", qos: .userInitiated)

    init() {}

    // MARK: - Reading

    @concurrent func readMenus(of app: MenuApp, limits: WalkLimits) async throws -> MenuSnapshot {
        guard AXIsProcessTrusted() else { throw MenuReadError.accessMissing }
        guard let running = Self.runningApp(bundleID: app.bundleID, preferring: nil) else {
            throw MenuReadError.appNotRunning
        }
        let process = running.processIdentifier
        guard process != ProcessInfo.processInfo.processIdentifier else { throw MenuReadError.noMenuBar }
        // The page cancels the read when the panel closes, which sets the flag the walk checks.
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await onQueue {
                let access = AXMenuAccess(process: process, timeout: limits.messagingTimeout)
                let start = ContinuousClock.now
                return try MenuWalker.walk(
                    access, app: app, processID: process, limits: limits, elapsed: { ContinuousClock.now - start },
                    shouldStop: { stop.isSet })
            }
        } onCancel: {
            stop.set()
        }
    }

    // MARK: - Pressing

    /// How long a press waits for the app to be in front again after the launcher closed.
    static let frontmostWait = Duration.milliseconds(800)
    /// How long it then lets the app's window take back key status before pressing.
    static let settleWait = Duration.milliseconds(60)
    /// How long the press itself may wait. An item that opens a modal dialog keeps the app busy, and
    /// the call then times out although the app did act on it.
    static let pressTimeout: Float = 1

    @concurrent func press(_ item: MenuItemRef) async throws {
        guard AXIsProcessTrusted() else { throw MenuReadError.accessMissing }
        guard let running = Self.runningApp(bundleID: item.bundleID, preferring: item.processID) else {
            throw MenuReadError.appQuit
        }
        let process = running.processIdentifier
        try await Self.bringForward(running)
        try await onQueue {
            let access = AXMenuAccess(process: process, timeout: Self.pressTimeout)
            let start = ContinuousClock.now
            guard let found = try MenuWalker.find(item.path, in: access, elapsed: { ContinuousClock.now - start })
            else { throw MenuReadError.itemGone }
            guard found.isEnabled else { throw MenuReadError.itemDisabled }
            let error = AXUIElementPerformAction(found.element.element, kAXPressAction as CFString)
            switch error {
            case .success, .cannotComplete:
                // Cannot complete: the app is busy with what the item started, such as a dialog.
                return
            case .apiDisabled:
                throw MenuReadError.accessMissing
            default:
                throw Self.isRunning(process) ? MenuReadError.itemGone : MenuReadError.appQuit
            }
        }
    }

    /// Waits until the launcher has given up key status and the app is in front, asking the app to
    /// come forward if it is not, then lets its window settle.
    private static func bringForward(_ running: NSRunningApplication) async throws {
        let process = running.processIdentifier
        let clock = ContinuousClock()
        let deadline = clock.now + frontmostWait
        var asked = false
        while clock.now < deadline {
            let (launcherIsKey, appIsInFront) = await MainActor.run {
                (
                    NSApplication.shared.keyWindow != nil,
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == process
                )
            }
            if !launcherIsKey && appIsInFront { break }
            if running.isTerminated { throw MenuReadError.appQuit }
            if !appIsInFront && !asked {
                // The launcher's panel never takes the front, so this happens only when something
                // else came forward meanwhile.
                asked = true
                running.activate(options: [])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Past the deadline the press goes ahead anyway: the item may not need the app in front.
        try await Task.sleep(for: settleWait)
    }

    // MARK: - Pieces

    /// Runs Accessibility work on the reader's queue and hands back its result.
    private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// The running app with this bundle ID: the one with this process ID when it still runs, else
    /// the active one, else the first.
    static func runningApp(bundleID: String, preferring process: Int32?) -> NSRunningApplication? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated
        }
        if let process, process != 0, let match = running.first(where: { $0.processIdentifier == process }) {
            return match
        }
        return running.first(where: \.isActive) ?? running.first
    }

    static func isRunning(_ process: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: process) else { return false }
        return !app.isTerminated
    }
}

/// A flag one thread sets and another reads.
nonisolated final class StopFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool { value.load(ordering: .relaxed) }

    func set() {
        value.store(true, ordering: .relaxed)
    }
}

/// The menu tree of one app over Accessibility. Every call is synchronous inter-process messaging,
/// so only ``AccessibilityMenus`` uses it, and only from its queue.
private nonisolated struct AXMenuAccess: MenuTreeAccess {
    /// An element, safe to hand between threads: `AXUIElement` is an immutable reference the
    /// system lets any thread use.
    struct Element: @unchecked Sendable {
        let element: AXUIElement
    }

    let process: pid_t
    let timeout: Float
    private let app: AXUIElement

    init(process: pid_t, timeout: Float) {
        self.process = process
        self.timeout = timeout
        app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, timeout)
    }

    /// The attributes read for every element, in one round trip.
    private static let attributes = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute,
        kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemMarkCharAttribute,
        kAXChildrenAttribute,
    ]

    func menuBarItems() throws -> [Element] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value)
        switch error {
        case .success: break
        case .apiDisabled: throw MenuReadError.accessMissing
        case .noValue, .attributeUnsupported, .notImplemented: throw MenuReadError.noMenuBar
        case .cannotComplete: throw AccessibilityMenus.isRunning(process) ? MenuReadError.notAnswering : .appQuit
        default: throw AccessibilityMenus.isRunning(process) ? MenuReadError.noMenuBar : .appQuit
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MenuReadError.noMenuBar }
        // The type ID was checked on the line above.
        let bar = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(bar, timeout)
        return try children(of: bar)
    }

    func read(_ element: Element) throws -> MenuElementInfo<Element> {
        AXUIElementSetMessagingTimeout(element.element, timeout)
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.element, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success, let list = values as? [AnyObject], list.count == Self.attributes.count else {
            throw failure(error)
        }
        let title = Self.string(list[0]) ?? ""
        let isEnabled = Self.bool(list[1]) ?? true
        let shortcut = ShortcutAttributes(
            character: Self.string(list[2]), virtualKey: Self.int(list[3]), glyph: Self.int(list[4]),
            modifiers: Self.int(list[5]))
        let mark = Self.string(list[6]) ?? ""
        // A menu item that opens a submenu has one child, the menu, whose children are the items.
        var submenuItems: [Element] = []
        if let menu = Self.elements(list[7]).first {
            AXUIElementSetMessagingTimeout(menu.element, timeout)
            submenuItems = try children(of: menu.element)
        }
        return MenuElementInfo(
            title: title, isEnabled: isEnabled, shortcut: shortcut, mark: mark, children: submenuItems)
    }

    private func children(of element: AXUIElement) throws -> [Element] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        switch error {
        case .success: return value.map(Self.elements) ?? []
        case .noValue, .attributeUnsupported: return []
        default: throw failure(error)
        }
    }

    /// What a failed call means: access lost, the app gone, or one element to leave out.
    private func failure(_ error: AXError) -> MenuReadError {
        if error == .apiDisabled { return .accessMissing }
        return AccessibilityMenus.isRunning(process) ? .elementFailed : .appQuit
    }

    // MARK: - Values

    /// True for a value slot that holds an error, as the multiple-value call reports a missing
    /// attribute.
    private static func isError(_ value: AnyObject) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError
    }

    private static func string(_ value: AnyObject) -> String? {
        guard !isError(value), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static func bool(_ value: AnyObject) -> Bool? {
        guard !isError(value), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private static func int(_ value: AnyObject) -> Int? {
        guard !isError(value), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func elements(_ value: AnyObject) -> [Element] {
        guard !isError(value), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return Element(element: unsafeDowncast(item, to: AXUIElement.self))
        }
    }
}
