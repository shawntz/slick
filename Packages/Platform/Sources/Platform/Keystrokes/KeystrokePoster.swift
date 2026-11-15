import Foundation
import Kit
import Synchronization

/// One thing to type into the frontmost app.
nonisolated public enum Keystroke: Hashable, Sendable {
    /// Command-V, with the V key of the current keyboard layout.
    case paste
    /// A key with modifiers, pressed and released.
    case key(KeyCombo)
    /// Text typed as Unicode characters. A line break is typed as the Return key.
    case text(String)

    /// Delete pressed `count` times.
    public static func deletes(_ count: Int) -> [Keystroke] {
        Array(repeating: .key(KeyCombo(.delete)), count: max(0, count))
    }

    /// Left arrow pressed `count` times.
    public static func lefts(_ count: Int) -> [Keystroke] {
        Array(repeating: .key(KeyCombo(.leftArrow)), count: max(0, count))
    }
}

/// Sends keystrokes to the frontmost app. ``CGEventKeystrokePoster`` is the live one; it needs
/// Accessibility.
nonisolated public protocol KeystrokePoster: Sendable {
    /// True when macOS lets this process send keystrokes. Never prompts.
    func canPost() -> Bool

    /// Sends the keystrokes in order. Throws ``PasteError/permissionMissing(_:)`` when sending is
    /// not allowed; nothing is sent then.
    func post(_ strokes: [Keystroke]) async throws
}

/// A poster that sends nothing and reports success, for run environments other than `live`, where
/// nothing may type into the user's apps.
nonisolated public struct InertKeystrokePoster: KeystrokePoster {
    public init() {}

    public func canPost() -> Bool { true }

    public func post(_ strokes: [Keystroke]) async throws {}
}

/// A poster that records what it was asked to send and sends nothing. For tests and scenarios.
nonisolated public final class RecordingKeystrokePoster: KeystrokePoster {
    private struct State {
        var posted: [Keystroke] = []
        var isAllowed = true
        var failure: (any Error & Sendable)?
        var refused: [[Keystroke]] = []
    }

    private let state = Mutex(State())

    public init(isAllowed: Bool = true) {
        state.withLock { $0.isAllowed = isAllowed }
    }

    /// Everything posted, oldest first.
    public var posted: [Keystroke] {
        state.withLock { $0.posted }
    }

    /// Whether ``canPost()`` says yes.
    public var isAllowed: Bool {
        get { state.withLock { $0.isAllowed } }
        set { state.withLock { $0.isAllowed = newValue } }
    }

    /// Every post that threw, oldest first.
    public var refused: [[Keystroke]] {
        state.withLock { $0.refused }
    }

    /// An error every post throws, with nothing posted, as when macOS cannot make the events.
    public var failure: (any Error & Sendable)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func canPost() -> Bool {
        isAllowed
    }

    public func post(_ strokes: [Keystroke]) async throws {
        try state.withLock { state in
            guard state.isAllowed, state.failure == nil else {
                state.refused.append(strokes)
                throw state.failure ?? PasteError.permissionMissing(.accessibility)
            }
            state.posted += strokes
        }
    }
}
