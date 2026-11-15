import Carbon
import Foundation
import Kit

/// The live hotkey system, on Carbon's `RegisterEventHotKey`. It needs no permission, and the
/// window server matches the chord, so it is the fastest path.
///
/// One event handler on the application target receives every press. Every call runs on the main
/// thread, as the Carbon Event Manager requires; the state below is touched only there.
nonisolated public final class CarbonHotkeySystem: HotkeySystem, @unchecked Sendable {
    /// The signature in every hotkey ID, so presses of other code's hotkeys are left alone.
    public static let signature: OSType = 0x5048_4B59  // "PHKY"

    /// Main thread only.
    private var handlerRef: EventHandlerRef?
    /// Main thread only.
    private var onPress: (@MainActor @Sendable (UInt32) -> Void)?

    public init() {}

    public func setPressHandler(_ handler: @escaping @MainActor @Sendable (UInt32) -> Void) {
        MainThread.run { onPress = handler }
    }

    public func register(keyCode: UInt32, modifiers: UInt32, number: UInt32) throws -> HotkeyToken {
        try MainThread.run {
            try installHandlerIfNeeded()
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: number), GetApplicationEventTarget(),
                0, &ref)
            guard status == noErr, let ref else { throw HotkeyError.registrationFailed(code: status) }
            return HotkeyToken(raw: UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(ref))))
        }
    }

    public func unregister(_ token: HotkeyToken) {
        MainThread.run {
            guard let pointer = UnsafeRawPointer(bitPattern: token.raw) else { return }
            _ = UnregisterEventHotKey(EventHotKeyRef(pointer))
        }
    }

    public func symbolicHotkeys() -> [SymbolicHotkey] {
        MainThread.run {
            var array: Unmanaged<CFArray>?
            guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]]
            else { return [] }
            return list.compactMap(Self.symbolicHotkey)
        }
    }

    /// One entry of `CopySymbolicHotKeys`, or nil when it has no key.
    static func symbolicHotkey(_ entry: [String: Any]) -> SymbolicHotkey? {
        guard let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue, (0..<0xFFFF).contains(code),
            let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
        else { return nil }
        let isEnabled = (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue ?? true
        return SymbolicHotkey(
            keyCode: UInt16(code), modifiers: modifiers & CarbonModifiers.relevantMask, isEnabled: isEnabled)
    }

    /// The number of the hotkey a Carbon event is about, or nil when the event is not a press of
    /// one of ours. Pure apart from reading the event, so a test can hand it an event it made.
    static func hotkeyNumber(in event: EventRef) -> UInt32? {
        guard GetEventClass(event) == OSType(kEventClassKeyboard), GetEventKind(event) == UInt32(kEventHotKeyPressed)
        else { return nil }
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
        guard status == noErr, hotkeyID.signature == signature else { return nil }
        return hotkeyID.id
    }

    @MainActor private func handle(_ event: EventRef) -> OSStatus {
        guard let number = Self.hotkeyNumber(in: event) else { return OSStatus(eventNotHandledErr) }
        onPress?(number)
        return noErr
    }

    @MainActor private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler holds this object unretained; the system lives as long as the app.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let system = Unmanaged<CarbonHotkeySystem>.fromOpaque(userData).takeUnretainedValue()
                guard Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated { system.handle(event) }
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { throw HotkeyError.registrationFailed(code: status) }
    }
}
