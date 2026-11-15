import Foundation
import Synchronization

/// A desktop in memory: displays, windows in front-to-back order, and a count of every frame set.
/// Scenarios, self-tests and benchmarks use it, so they can never move a real window, and tests read
/// it to see what the feature did.
///
/// Windows behave the way apps do where it matters to the geometry: a window keeps a minimum size,
/// a fixed-size window keeps its size, a full screen window refuses to move, and a window that
/// cannot move ignores every frame.
nonisolated final class SimulatedWindows: WindowService {
    /// One simulated window.
    struct Window: Hashable, Sendable {
        var ref: WindowRef
        var title: String
        var appName: String
        var bundleID: String?
        var frame: Frame
        var minimumSize = Size(width: 0, height: 0)
        var isMinimized = false
        var isFullScreen = false
        var canMove = true
        var canResize = true
        var supportsFullScreen = true
        var isAppHidden = false
    }

    private struct State {
        var displays: [Display]
        /// Front to back. The focused window is the first one that is not minimized or hidden.
        var windows: [Window]
        var accessibilityGranted = true
        var frameSets = 0
    }

    private let state: Mutex<State>

    init(displays: [Display], windows: [Window]) {
        state = Mutex(State(displays: displays, windows: windows))
    }

    // MARK: - Reading and changing the desktop

    var displays: [Display] {
        get { state.withLock { $0.displays } }
        set { state.withLock { $0.displays = newValue } }
    }

    /// Every window, front to back.
    var windows: [Window] {
        get { state.withLock { $0.windows } }
        set { state.withLock { $0.windows = newValue } }
    }

    /// The window commands act on.
    var focused: Window? {
        state.withLock { state in Self.focusedIndex(in: state).map { state.windows[$0] } }
    }

    /// False makes every call throw ``WindowError/accessibilityMissing``, as when the user turns
    /// Accessibility off while the app runs.
    var accessibilityGranted: Bool {
        get { state.withLock { $0.accessibilityGranted } }
        set { state.withLock { $0.accessibilityGranted = newValue } }
    }

    /// How many times a frame was set, across all windows.
    var frameSets: Int { state.withLock { $0.frameSets } }

    /// Changes one window by reference.
    func update(_ ref: WindowRef, _ change: (inout Window) -> Void) {
        state.withLock { state in
            guard let index = state.windows.firstIndex(where: { $0.ref == ref }) else { return }
            change(&state.windows[index])
        }
    }

    // MARK: - WindowService

    @concurrent func arrangeFocusedWindow(_ request: LayoutRequest) async throws -> LayoutOutcome {
        try state.withLock { state in
            guard state.accessibilityGranted else { throw WindowError.accessibilityMissing }
            let index = Self.focusedIndex(in: state)
            let current = index.map { index in
                let window = state.windows[index]
                return WindowState(
                    key: window.ref.key, frame: window.frame, isFullScreen: window.isFullScreen,
                    canMove: window.canMove, canResize: window.canResize)
            }
            return try Arranger.arrange(request, window: current, displays: state.displays) { frame in
                guard let index else { throw WindowError.windowGone }
                state.frameSets += 1
                return Self.setFrame(frame, of: &state.windows[index])
            }
        }
    }

    @concurrent func toggleFullScreen() async throws -> FullScreenOutcome {
        try state.withLock { state in
            guard state.accessibilityGranted else { throw WindowError.accessibilityMissing }
            guard let index = Self.focusedIndex(in: state) else { return .noWindow }
            guard state.windows[index].supportsFullScreen else { return .unsupported }
            state.windows[index].isFullScreen.toggle()
            return state.windows[index].isFullScreen ? .entered : .exited
        }
    }

    @concurrent func openWindows() async throws -> [OpenWindow] {
        try state.withLock { state in
            guard state.accessibilityGranted else { throw WindowError.accessibilityMissing }
            let focused = Self.focusedIndex(in: state)
            let listed = state.windows.enumerated().map { index, window in
                OpenWindow(
                    ref: window.ref, title: window.title, appName: window.appName, bundleID: window.bundleID,
                    isMinimized: window.isMinimized, isAppHidden: window.isAppHidden, isFocused: index == focused)
            }
            return listed.filter { !$0.isMinimized } + listed.filter(\.isMinimized)
        }
    }

    @concurrent func focus(_ ref: WindowRef) async throws {
        try state.withLock { state in
            let index = try Self.index(of: ref, in: state)
            var window = state.windows.remove(at: index)
            window.isMinimized = false
            state.windows.insert(window, at: 0)
            for other in state.windows.indices where state.windows[other].appName == window.appName {
                state.windows[other].isAppHidden = false
            }
        }
    }

    @concurrent func minimize(_ ref: WindowRef) async throws {
        try state.withLock { state in
            let index = try Self.index(of: ref, in: state)
            guard !state.windows[index].isFullScreen else { throw WindowError.refused }
            state.windows[index].isMinimized = true
        }
    }

    @concurrent func close(_ ref: WindowRef) async throws {
        try state.withLock { state in
            let index = try Self.index(of: ref, in: state)
            state.windows.remove(at: index)
        }
    }

    // MARK: - Rules

    private static func focusedIndex(in state: State) -> Int? {
        state.windows.firstIndex { !$0.isMinimized && !$0.isAppHidden }
    }

    private static func index(of ref: WindowRef, in state: State) throws -> Int {
        guard state.accessibilityGranted else { throw WindowError.accessibilityMissing }
        guard let index = state.windows.firstIndex(where: { $0.ref == ref }) else { throw WindowError.windowGone }
        return index
    }

    /// Applies a frame the way an app would and returns the frame the window took.
    private static func setFrame(_ frame: Frame, of window: inout Window) -> Frame {
        guard window.canMove, !window.isFullScreen else { return window.frame }
        var size = window.frame.size
        if window.canResize {
            size = Size(
                width: max(frame.width, window.minimumSize.width), height: max(frame.height, window.minimumSize.height))
        }
        window.frame = Frame(x: frame.x, y: frame.y, width: size.width, height: size.height)
        return window.frame
    }

    // MARK: - The sample desktop

    /// The desktop scenarios and self-tests see: a Retina laptop display with a menu bar and a Dock,
    /// an external display to its right, and four windows of made-up apps.
    static func sample() -> SimulatedWindows {
        SimulatedWindows(displays: [sampleLaptop, sampleExternal], windows: sampleWindows)
    }

    /// 1512 by 982 points at scale 2, with a 33 point menu bar and a 70 point Dock at the bottom.
    static let sampleLaptop = Display(
        id: 1, frame: Frame(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: Frame(x: 0, y: 33, width: 1512, height: 879), scale: 2)

    /// 1920 by 1080 points at scale 1, to the right of the laptop, with a 25 point menu bar.
    static let sampleExternal = Display(
        id: 2, frame: Frame(x: 1512, y: -98, width: 1920, height: 1080),
        visibleFrame: Frame(x: 1512, y: -73, width: 1920, height: 1055), scale: 1)

    static let sampleWindows: [Window] = [
        Window(
            ref: WindowRef(process: 101, token: 1), title: "Draft", appName: "Example Editor",
            bundleID: "com.example.editor", frame: Frame(x: 120, y: 90, width: 900, height: 640),
            minimumSize: Size(width: 400, height: 300)),
        Window(
            ref: WindowRef(process: 102, token: 1), title: "Start Page", appName: "Example Browser",
            bundleID: "com.example.browser", frame: Frame(x: 1700, y: 40, width: 1200, height: 800)),
        Window(
            ref: WindowRef(process: 101, token: 2), title: "Notes", appName: "Example Editor",
            bundleID: "com.example.editor", frame: Frame(x: 300, y: 200, width: 700, height: 500)),
        Window(
            ref: WindowRef(process: 103, token: 1), title: "Inbox", appName: "Example Mail",
            bundleID: "com.example.mail", frame: Frame(x: 200, y: 150, width: 1000, height: 700), isMinimized: true),
    ]
}
