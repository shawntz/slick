import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Kit

/// The live keystroke poster, on `CGEvent`. It needs Accessibility: ``canPost()`` checks with
/// `CGPreflightPostEventAccess` and `AXIsProcessTrusted`, which never prompt, and ``post(_:)``
/// sends nothing without the grant, because a refused post can make macOS show its own prompt.
///
/// Every event carries ``eventTag`` in its source user data, so this app's own keyboard tap can
/// tell its keystrokes from the user's. Text goes in chunks of at most 20 UTF-16 units, the most a
/// keyboard event carries reliably.
nonisolated public struct CGEventKeystrokePoster: KeystrokePoster {
    /// The value in `eventSourceUserData` that marks an event as this app's own.
    public static let eventTag: Int64 = 0x5645_5452_4F4B

    /// The pause between two events. Some apps drop keys that arrive closer together.
    public let interval: Duration

    public init(interval: Duration = .milliseconds(2)) {
        self.interval = interval
    }

    /// `AXIsProcessTrusted` answers in under a microsecond, so it goes first; the post event check
    /// may wait on the TCC daemon.
    public func canPost() -> Bool {
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    @concurrent public func post(_ strokes: [Keystroke]) async throws {
        guard canPost() else { throw PasteError.permissionMissing(.accessibility) }
        let source = CGEventSource(stateID: .combinedSessionState)
        for stroke in strokes {
            switch stroke {
            case .paste:
                let code = await MainActor.run { KeyboardLayout.keyCode(producing: "v") } ?? Key.v.code
                await press(KeyCombo(Key(code: code), .command), source: source)
            case .key(let combo):
                await press(combo, source: source)
            case .text(let text):
                for piece in Self.pieces(of: text) {
                    switch piece {
                    case .lineBreak: await press(KeyCombo(.return), source: source)
                    case .characters(let units): await type(units, source: source)
                    }
                }
            }
        }
    }

    private func press(_ combo: KeyCombo, source: CGEventSource?) async {
        let flags = Self.flags(for: combo.modifiers)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.key.code, keyDown: isDown)
            else { continue }
            event.flags = flags
            send(event)
            try? await Task.sleep(for: interval)
        }
    }

    private func type(_ units: [UniChar], source: CGEventSource?) async {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            send(event)
            try? await Task.sleep(for: interval)
        }
    }

    private func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cgSessionEventTap)
    }

    /// The `CGEvent` flags for Kit's modifiers.
    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// One keyboard event's worth of text, or a line break typed as Return.
    enum Piece: Hashable {
        case characters([UniChar])
        case lineBreak
    }

    /// Splits text into keyboard events: runs of whole characters of at most 20 UTF-16 units, and
    /// line breaks. A character is never split across two events.
    static func pieces(of text: String, limit: Int = 20) -> [Piece] {
        var pieces: [Piece] = []
        var run: [UniChar] = []
        for character in text {
            if character.isNewline {
                if !run.isEmpty { pieces.append(.characters(run)) }
                run = []
                pieces.append(.lineBreak)
                continue
            }
            let units = Array(String(character).utf16)
            if !run.isEmpty, run.count + units.count > limit {
                pieces.append(.characters(run))
                run = []
            }
            run += units
        }
        if !run.isEmpty { pieces.append(.characters(run)) }
        return pieces
    }
}

/// Finds keys on the current keyboard layout.
nonisolated enum KeyboardLayout {
    /// The virtual key that types `character` while Command is held, or nil when the layout has
    /// none. With Command held, layouts such as "Dvorak - QWERTY ⌘" switch to QWERTY, which is the
    /// key a shortcut needs. Text Input Sources must be read on the main thread.
    @MainActor static func keyCode(producing character: Character) -> UInt16? {
        guard let target = String(character).utf16.first,
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { buffer -> UInt16? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var output = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), commandState, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, output.count, &length, &output)
                if status == noErr, length == 1, output[0] == target { return code }
            }
            return nil
        }
    }
}
