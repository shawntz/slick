import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// The live window service, over the Accessibility API.
///
/// Every Accessibility call runs on one serial background queue, so no call is ever on the main
/// thread and two commands never interleave their moves. Only the display list is read on the main
/// actor, because `NSScreen` belongs to it. That read is a lookup in AppKit's own copy and costs
/// microseconds.
///
/// It needs the Accessibility permission for other apps' windows. Nothing here asks for it: a
/// missing grant surfaces as ``WindowError/accessibilityMissing`` and the host runs its grant flow.
///
/// This class changes the Mac. Tests use ``SimulatedWindows``. The one live test in the package acts
/// on a window it created itself, through ``AXElement``, and never on the frontmost app.
nonisolated final class AccessibilityWindows: WindowService {
    private let queue = DispatchQueue(label: "windows.accessibility", qos: .userInitiated)

    init() {}

    // MARK: - Layout commands

    @concurrent func arrangeFocusedWindow(_ request: LayoutRequest) async throws -> LayoutOutcome {
        let displays = await Self.displays()
        return try await onQueue {
            guard let (process, app, window) = try Self.focusedWindow() else { return .unchanged(.noWindow) }
            let state = try Self.state(of: window, process: process)
            return try Arranger.arrange(request, window: state, displays: displays) { frame in
                try window.setFrame(frame, canResize: state?.canResize ?? false, app: app)
            }
        }
    }

    @concurrent func toggleFullScreen() async throws -> FullScreenOutcome {
        try await onQueue {
            guard let (_, _, window) = try Self.focusedWindow() else { return .noWindow }
            guard window.isSettable(Self.fullScreenAttribute) else { return .unsupported }
            let isFullScreen = try window.bool(Self.fullScreenAttribute) ?? false
            try window.set(Self.fullScreenAttribute, !isFullScreen)
            return isFullScreen ? .exited : .entered
        }
    }

    // MARK: - Switch Windows

    @concurrent func openWindows() async throws -> [OpenWindow] {
        try await onQueue {
            let ownProcess = ProcessInfo.processInfo.processIdentifier
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != ownProcess && !$0.isTerminated
            }
            let order = Self.windowStackingOrder()
            // Apps answer one at a time over Accessibility, so ask them side by side. Each worker
            // makes its own elements and returns plain values.
            let found = Mutex<[[ListedWindow]]>(Array(repeating: [], count: apps.count))
            let missingAccess = Atomic<Bool>(false)
            let snapshots = apps.map(AppSnapshot.init)
            DispatchQueue.concurrentPerform(iterations: snapshots.count) { index in
                do {
                    let listed = try Self.windows(
                        of: snapshots[index], isFrontmost: snapshots[index].process == frontmost)
                    found.withLock { $0[index] = listed }
                } catch WindowError.accessibilityMissing {
                    missingAccess.store(true, ordering: .relaxed)
                } catch {
                    // An app that does not answer is left out. The others still list.
                }
            }
            if missingAccess.load(ordering: .relaxed) { throw WindowError.accessibilityMissing }
            return Self.mostRecentFirst(found.withLock { $0.flatMap(\.self) }, stackingOrder: order)
        }
    }

    @concurrent func focus(_ ref: WindowRef) async throws {
        try await onQueue {
            let (app, window) = try Self.find(ref)
            if try window.bool(kAXMinimizedAttribute) == true {
                try window.set(kAXMinimizedAttribute, false)
            }
            if let running = NSRunningApplication(processIdentifier: ref.process), running.isHidden {
                running.unhide()
            }
            try? window.perform(kAXRaiseAction)
            try? window.set(kAXMainAttribute, true)
            try app.set(kAXFrontmostAttribute, true)
        }
    }

    @concurrent func minimize(_ ref: WindowRef) async throws {
        try await onQueue {
            let (_, window) = try Self.find(ref)
            guard window.isSettable(kAXMinimizedAttribute) else { throw WindowError.refused }
            try window.set(kAXMinimizedAttribute, true)
        }
    }

    @concurrent func close(_ ref: WindowRef) async throws {
        try await onQueue {
            let (_, window) = try Self.find(ref)
            guard let button = try window.element(kAXCloseButtonAttribute) else { throw WindowError.refused }
            try button.perform(kAXPressAction)
        }
    }

    // MARK: - Pieces

    /// The attribute macOS uses for a window's full screen state. It has no public constant.
    static let fullScreenAttribute = "AXFullScreen"

    /// Runs Accessibility work on the service's queue and hands back its result.
    private func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Every display, read from AppKit on the main actor and turned into the Accessibility space.
    /// The first screen is the main display, whose top-left corner is the origin of that space.
    @MainActor static func displays() -> [Display] {
        let screens = NSScreen.screens
        guard let main = screens.first else { return [] }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screens.map { screen in
            Display.fromAppKit(
                id: (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0, frame: Frame(screen.frame),
                visibleFrame: Frame(screen.visibleFrame), scale: Double(screen.backingScaleFactor),
                mainHeight: Double(main.frame.height))
        }
    }

    /// The frontmost app's focused window. Nil when this app is frontmost, as it never arranges its
    /// own panel, or when the frontmost app has no focused window.
    private static func focusedWindow() throws -> (process: pid_t, app: AXElement, window: AXElement)? {
        guard let process = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            process != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let app = AXElement.application(process)
        guard let window = try app.element(kAXFocusedWindowAttribute) else { return nil }
        return (process, app, window)
    }

    /// What the planner needs to know about a window. Nil when it has no frame.
    static func state(of window: AXElement, process: pid_t) throws -> WindowState? {
        guard let frame = try window.frame() else { return nil }
        return WindowState(
            key: WindowRef(process: process, token: window.token).key, frame: frame,
            isFullScreen: try window.bool(fullScreenAttribute) ?? false,
            canMove: window.isSettable(kAXPositionAttribute), canResize: window.isSettable(kAXSizeAttribute))
    }

    /// The window a reference names, found again among its app's windows.
    private static func find(_ ref: WindowRef) throws -> (app: AXElement, window: AXElement) {
        guard NSRunningApplication(processIdentifier: ref.process) != nil else { throw WindowError.windowGone }
        let app = AXElement.application(ref.process)
        guard let window = try app.elements(kAXWindowsAttribute).first(where: { $0.token == ref.token }) else {
            throw WindowError.windowGone
        }
        return (app, window)
    }

    /// An app's windows that a person would switch to: standard windows and dialogs, minimized or not.
    private static func windows(of app: AppSnapshot, isFrontmost: Bool) throws -> [ListedWindow] {
        let element = AXElement.application(app.process)
        let focused = isFrontmost ? try element.element(kAXFocusedWindowAttribute)?.token : nil
        var listed: [ListedWindow] = []
        for (position, window) in try element.elements(kAXWindowsAttribute).enumerated() {
            do {
                guard try window.string(kAXRoleAttribute) == kAXWindowRole else { continue }
                let subrole = try window.string(kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let token = window.token
                listed.append(
                    ListedWindow(
                        window: OpenWindow(
                            ref: WindowRef(process: app.process, token: token),
                            title: try window.string(kAXTitleAttribute) ?? "",
                            appName: app.name, bundleID: app.bundleID,
                            isMinimized: try window.bool(kAXMinimizedAttribute) ?? false, isAppHidden: app.isHidden,
                            isFocused: token == focused),
                        frame: try window.frame(), positionInApp: position))
            } catch WindowError.accessibilityMissing {
                throw WindowError.accessibilityMissing
            } catch {
                // A window that closed while it was read is left out. The app's others still list.
            }
        }
        return listed
    }

    /// The on-screen windows of normal apps, front to back, as process and bounds. This reads no
    /// window titles, which need Screen Recording, and shows no prompt.
    private static func windowStackingOrder() -> [(process: pid_t, frame: Frame)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                let process = entry[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return (process, Frame(rect))
        }
    }

    /// Orders listed windows most recently used first: windows on screen in their stacking order,
    /// then those on other Spaces or in hidden apps, then minimized ones. A window is matched to
    /// its place in the stack by its process and frame, since Accessibility gives no window number.
    static func mostRecentFirst(
        _ listed: [ListedWindow], stackingOrder: [(process: pid_t, frame: Frame)]
    ) -> [OpenWindow] {
        // Each process's places in the stack, front first, so a window is compared only with its
        // own app's. Matching against the whole stack for every window grows with the square of the
        // number of windows.
        var places: [pid_t: [Int]] = [:]
        for (index, entry) in stackingOrder.enumerated() {
            places[entry.process, default: []].append(index)
        }
        var ranked: [(rank: Int, tieBreak: Int, window: OpenWindow)] = []
        ranked.reserveCapacity(listed.count)
        for item in listed {
            var rank = Int.max
            let process = item.window.ref.process
            if !item.window.isMinimized, let frame = item.frame,
                let position = places[process]?.firstIndex(where: { stackingOrder[$0].frame.isClose(to: frame) }),
                let index = places[process]?.remove(at: position)
            {
                rank = index
            } else if !item.window.isMinimized {
                rank = stackingOrder.count + 1
            }
            ranked.append((rank, item.positionInApp, item.window))
        }
        // A stable order for ties keeps each app's own window order.
        return ranked.enumerated().sorted { lhs, rhs in
            if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
            if lhs.element.tieBreak != rhs.element.tieBreak { return lhs.element.tieBreak < rhs.element.tieBreak }
            return lhs.offset < rhs.offset
        }.map(\.element.window)
    }
}

/// A window found while listing, with what ordering needs.
nonisolated struct ListedWindow: Sendable {
    var window: OpenWindow
    var frame: Frame?
    /// Its place in the app's own window list, front first.
    var positionInApp: Int
}

/// What listing needs from a running app, read once on the service's queue.
private nonisolated struct AppSnapshot: Sendable {
    var process: pid_t
    var name: String
    var bundleID: String?
    var isHidden: Bool

    init(_ app: NSRunningApplication) {
        process = app.processIdentifier
        name = app.localizedName ?? app.bundleIdentifier ?? ""
        bundleID = app.bundleIdentifier
        isHidden = app.isHidden
    }
}

extension Frame {
    /// A frame from a Core Graphics rectangle.
    nonisolated init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }
}
