import CoreGraphics
import Foundation
import Kit

/// Where text expansion hears typing. ``EventTapSource`` is the live one.
nonisolated public protocol KeyEventSource: Sendable {
    /// Starts sending events to `handler`, on a thread of the source's choosing. False when the
    /// source could not start, such as when macOS refused the tap. Calling it while started does
    /// nothing and returns true.
    func start(_ handler: @escaping @Sendable (TypingEvent) -> Void) -> Bool

    /// Stops sending events. Safe to call when stopped.
    func stop()
}

/// A source that never sends an event, for run environments other than `live`, where hardware
/// key events are ignored.
nonisolated public struct SilentKeyEventSource: KeyEventSource {
    public init() {}

    public func start(_ handler: @escaping @Sendable (TypingEvent) -> Void) -> Bool { true }

    public func stop() {}
}

/// The live source: a listen-only `CGEventTap` for key downs, modifier changes and mouse downs, on
/// its own thread with its own run loop.
///
/// A keyboard tap needs Input Monitoring, and creating one before the user decided may show the
/// system prompt. So ``start(_:)`` creates the tap only when `CGPreflightListenEventAccess` says
/// yes, and returns false otherwise. Events this app posts itself carry
/// ``CGEventKeystrokePoster/eventTag`` and are skipped. When macOS disables the tap because it
/// was slow, it is enabled again.
nonisolated public final class EventTapSource: KeyEventSource, @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var running: Running?
    /// Guarded by `lock`.
    private var handler: (@Sendable (TypingEvent) -> Void)?

    private struct Running {
        var tap: CFMachPort
        var runLoop: CFRunLoop
    }

    public init() {}

    /// The tap holds this object unretained, so it must not outlive it.
    deinit {
        stop()
    }

    public func start(_ handler: @escaping @Sendable (TypingEvent) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running == nil else { return true }
        guard CGPreflightListenEventAccess() else { return false }
        self.handler = handler
        let ready = DispatchSemaphore(value: 0)
        let handoff = TapHandoff<Running>()
        let thread = Thread { [self] in
            let mask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: mask, callback: eventTapCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                ready.signal()
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                CFMachPortInvalidate(tap)
                ready.signal()
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            // When start gave up waiting, nobody could ever stop this tap, so it goes at once. Once
            // handed over, the source is in the loop, so a stop that invalidates the tap ends the
            // loop even before it runs.
            guard handoff.offer(Running(tap: tap, runLoop: CFRunLoopGetCurrent())) else {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                CFMachPortInvalidate(tap)
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        thread.name = "platform.text-expansion.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        running = handoff.take()
        if running == nil { self.handler = nil }
        return running != nil
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let running else { return }
        CGEvent.tapEnable(tap: running.tap, enable: false)
        // Invalidating removes the tap from its run loop, so the thread ends even when it had not
        // started running the loop yet, when stopping it alone would do nothing.
        CFMachPortInvalidate(running.tap)
        CFRunLoopStop(running.runLoop)
        self.running = nil
    }

    /// Called on the tap thread for every event.
    fileprivate func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ running?.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != CGEventKeystrokePoster.eventTag,
            let typing = TypingEventDecoder.event(type: type, event: event),
            let handler = lock.withLock({ handler })
        else { return }
        handler(typing)
    }

}

/// Carries a value from a thread that makes it to a caller that waits a limited time. Once the
/// caller took nothing, a late value is refused, and the thread must undo what it made.
nonisolated final class TapHandoff<Value>: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var value: Value?
    /// Guarded by `lock`.
    private var isAbandoned = false

    /// Called by the thread. False when the caller already gave up.
    func offer(_ value: Value) -> Bool {
        lock.withLock {
            guard !isAbandoned else { return false }
            self.value = value
            return true
        }
    }

    /// Called by the caller once it stops waiting. Nil when nothing came, and then nothing will.
    func take() -> Value? {
        lock.withLock {
            if value == nil { isAbandoned = true }
            return value
        }
    }
}

private nonisolated func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let info {
        Unmanaged<EventTapSource>.fromOpaque(info).takeUnretainedValue().receive(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Turns keyboard and mouse events into ``TypingEvent``s. Pure apart from reading the event.
nonisolated enum TypingEventDecoder {
    /// Key codes that move the insertion point: arrows, Home, End, Page Up, Page Down.
    static let navigationKeys: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79]
    /// Function keys F1 to F12.
    static let functionKeys: Set<UInt16> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]

    static func event(type: CGEventType, event: CGEvent) -> TypingEvent? {
        switch type {
        case .keyDown:
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(
                maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            let characters = String(utf16CodeUnits: units, count: min(length, units.count))
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return keyDown(keyCode: code, flags: event.flags, characters: characters)
        case .flagsChanged:
            return .modifiers
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .click
        default:
            return nil
        }
    }

    /// A key down by its code, flags and the text it typed.
    static func keyDown(keyCode: UInt16, flags: CGEventFlags, characters: String) -> TypingEvent {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .shortcut }
        switch keyCode {
        case Key.delete.code: return .backspace
        case Key.forwardDelete.code: return .forwardDelete
        case Key.escape.code: return .escape
        case let code where navigationKeys.contains(code) || functionKeys.contains(code): return .navigation
        default: break
        }
        // Keys without text of their own report control characters or private-use function key
        // characters. Return and Tab type text; the rest move nothing we can follow.
        if characters == "\r" || characters == "\n" || characters == "\t" { return .characters(characters) }
        if characters.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) {
            return .navigation
        }
        return .characters(characters)
    }
}
