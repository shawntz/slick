import Foundation
import Kit

/// What the feature needs from the system: the frontmost app's focused window, every open window,
/// and a few things to do to one. It lives in this package because no other feature needs it.
///
/// Every requirement is `@concurrent`, so the work runs off the main thread whoever calls it. The
/// live service uses Accessibility and needs the Accessibility permission. The isolated one is a
/// simulated desktop that touches nothing.
nonisolated protocol WindowService: Sendable {
    /// Reads the focused window and the displays, plans the frame, sets it and reads it back, in
    /// one pass. See ``Arranger``.
    @concurrent func arrangeFocusedWindow(_ request: LayoutRequest) async throws -> LayoutOutcome

    /// Turns full screen on or off for the focused window.
    @concurrent func toggleFullScreen() async throws -> FullScreenOutcome

    /// Every open window across apps, most recently used first. Minimized windows come last.
    @concurrent func openWindows() async throws -> [OpenWindow]

    /// Brings a window and its app forward, showing it first if it is minimized or hidden.
    @concurrent func focus(_ window: WindowRef) async throws

    @concurrent func minimize(_ window: WindowRef) async throws

    /// Presses the window's close button. The app may ask about unsaved changes.
    @concurrent func close(_ window: WindowRef) async throws
}

/// What Toggle Full Screen did.
nonisolated enum FullScreenOutcome: Hashable, Sendable {
    case entered
    case exited
    case noWindow
    /// The window has no full screen mode, such as a panel or a fixed-size window.
    case unsupported
}

/// Why a window service call failed.
nonisolated enum WindowError: Error, Hashable, Sendable, LocalizedError {
    /// Accessibility was turned off after the host checked it.
    case accessibilityMissing
    /// The window closed, or its app quit, since the list was read.
    case windowGone
    /// The app did not do what was asked.
    case refused

    var errorDescription: String? {
        switch self {
        case .accessibilityMissing: Strings.accessibilityMissing
        case .windowGone: Strings.windowGone
        case .refused: Strings.refused
        }
    }
}

/// Names one open window for as long as it stays open: its process and a token the service gives
/// it. The live service's token is the hash of the window's Accessibility element, which stays the
/// same for one window and is not kept across launches.
nonisolated struct WindowRef: Hashable, Sendable, Codable {
    var process: Int32
    var token: Int

    /// The row key, `<process>_<token>`. The token may be negative.
    var key: String { "\(process)_\(token)" }

    init(process: Int32, token: Int) {
        self.process = process
        self.token = token
    }

    /// Parses a row key.
    init?(key: String) {
        let parts = key.split(separator: "_")
        guard parts.count == 2, let process = Int32(parts[0]), let token = Int(parts[1]) else { return nil }
        self.init(process: process, token: token)
    }
}

/// One open window, as Switch Windows lists it.
nonisolated struct OpenWindow: Hashable, Sendable, Codable {
    var ref: WindowRef
    /// The window's title. Empty for windows without one. The row shows the app's name then.
    var title: String
    var appName: String
    var bundleID: String?
    var isMinimized = false
    var isAppHidden = false
    /// The frontmost app's focused window.
    var isFocused = false
}

/// The window service for each kind of run. Scenarios, self-tests and benchmarks get a simulated
/// desktop, so they can never move a real window.
nonisolated enum WindowServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any WindowService { AccessibilityWindows() }
    static func isolated(_ context: FeatureContext) -> any WindowService { SimulatedWindows.sample() }
}
