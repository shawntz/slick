import Foundation

/// The state of the Mac that prediction conditions on.
///
/// Platform tracks it. Root feeds it to the engine when it changes, never when the hotkey fires.
public struct SystemContext: Hashable, Sendable {
    /// Where sound plays.
    public enum AudioRoute: String, Hashable, Sendable, CaseIterable {
        /// The Mac's own speakers.
        case builtIn
        /// Wired headphones.
        case headphones
        /// A Bluetooth device.
        case bluetooth
        /// Any other output, such as a display, USB or AirPlay.
        case external
        /// Not known yet.
        case unknown
    }

    /// The bundle ID of the frontmost app. Never Slick itself: while the panel is up it is the app
    /// that was frontmost before. Nil when there is none.
    public var frontmostBundleID: String?
    /// True while the Mac runs on battery.
    public var onBattery: Bool
    /// Connected displays, at least 1.
    public var displayCount: Int
    public var audioRoute: AudioRoute
    /// True while a Focus is on. False when unknown.
    public var isFocusOn: Bool

    public init(
        frontmostBundleID: String? = nil,
        onBattery: Bool = false,
        displayCount: Int = 1,
        audioRoute: AudioRoute = .unknown,
        isFocusOn: Bool = false
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.onBattery = onBattery
        self.displayCount = displayCount
        self.audioRoute = audioRoute
        self.isFocusOn = isFocusOn
    }
}

/// Tracks the ``SystemContext`` and the start of each session at the Mac.
///
/// Platform implements it. Root reads it. It never prompts for a permission.
public protocol SystemContextService: Sendable {
    /// The context now. Never blocks: it returns the last value tracked.
    func current() -> SystemContext

    /// The context each time it changes from now on. It ends when the consuming task is cancelled.
    func changes() -> AsyncStream<SystemContext>

    /// The moment of each session start from now on: the Mac woke or the screen unlocked. Root
    /// refreshes suggestions then. It ends when the consuming task is cancelled.
    func sessionStarts() -> AsyncStream<Date>
}
