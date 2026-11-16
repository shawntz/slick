/// When Large Type goes away: at any key, any click, or when its window stops being key, as when
/// the user switches to another app. A held key's repeats do not count, so the repeats of the
/// Command-L that opened it never close it at once.
///
/// The window reports what happens and hides when told; the rules live here, so tests check them
/// without a window.
public final class LargeTypeDismissal {
    /// Something that may hide Large Type.
    nonisolated public enum Event: Sendable, Equatable {
        /// A key went down. `isRepeat` for the repeats of a held key.
        case keyDown(isRepeat: Bool)
        /// A mouse button went down, on Large Type or anywhere the window hears of it.
        case click
        /// The window stopped being key: another window or app took the keyboard.
        case resignedKey
        /// The app stopped being the active app.
        case appResignedActive
    }

    /// True from ``shown()`` until something hides it.
    public private(set) var isShown = false
    /// Runs once each time it hides.
    public var onDismiss: (() -> Void)?

    public init() {}

    /// Large Type is on screen now.
    public func shown() {
        isShown = true
    }

    /// Hides Large Type when the event calls for it. True when it hid.
    @discardableResult
    public func handle(_ event: Event) -> Bool {
        guard isShown else { return false }
        if case .keyDown(isRepeat: true) = event { return false }
        isShown = false
        onDismiss?()
        return true
    }

    /// Hides it now, as when another text replaces it or the host closes it.
    public func reset() {
        isShown = false
    }
}
