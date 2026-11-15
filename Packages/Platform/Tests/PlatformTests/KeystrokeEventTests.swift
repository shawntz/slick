import CoreGraphics
import Foundation
import Kit
import KitTesting
import Testing

@testable import Platform

/// The keystroke poster makes every event before it sends any. Events here are made and read, and
/// never posted.
@Suite(.timeLimit(.minutes(1))) struct KeystrokeEventTests {
    static func make(_ code: CGKeyCode, _ isDown: Bool) -> CGEvent? {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
    }

    static func text(of event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }

    @Test func everyStrokeBecomesADownAndAnUpEvent() throws {
        let events = try CGEventKeystrokePoster.events(
            for: [.paste, .key(KeyCombo(.delete)), .text("ab\nc")], pasteKey: 9, make: Self.make)
        #expect(events.count == 2 + 2 + 6)
        #expect(events[0].getIntegerValueField(.keyboardEventKeycode) == 9)
        #expect(events[0].flags.contains(.maskCommand) && events[1].flags.contains(.maskCommand))
        #expect(events[2].getIntegerValueField(.keyboardEventKeycode) == Int64(Key.delete.code))
        #expect(Self.text(of: events[4]) == "ab")
        #expect(events[6].getIntegerValueField(.keyboardEventKeycode) == Int64(Key.return.code))
        #expect(Self.text(of: events[8]) == "c")
    }

    /// Found in review: an event macOS did not make was skipped, so an expansion could delete its
    /// keyword and then type nothing, and a paste reported success.
    @Test func anEventMacOSDidNotMakeStopsTheWholePostBeforeAnythingIsSent() {
        var made = 0
        #expect(throws: CGEventKeystrokePoster.eventUnavailable) {
            _ = try CGEventKeystrokePoster.events(for: Keystroke.deletes(2) + [.text("Best,\nSam")], pasteKey: 9) {
                code, isDown in
                made += 1
                return made == 5 ? nil : Self.make(code, isDown)
            }
        }
        #expect(CGEventKeystrokePoster.eventUnavailable.title == "Could Not Send Keystrokes")
    }
}

/// Text expansion tells a missing permission from any other failure to type.
@Suite(.timeLimit(.minutes(1))) struct ExpansionFailureTests {
    let permissions = FakePermissions()
    let source = FakeKeySource()
    let poster = RecordingKeystrokePoster()

    func makeCenter() -> TextExpansionCenter {
        TextExpansionCenter(
            permissions: permissions, source: source, poster: poster, secureInput: FakeSecureInput(),
            frontmostBundleID: { "com.example.editor" }, focusChanges: { AsyncStream { _ in } },
            clickRecheckDelay: .milliseconds(10), ownAppIsKey: { false })
    }

    /// Found in review: every failure to type read as Accessibility taken away, so a failure that
    /// was not about permissions stopped expansion and asked for a grant the app already had.
    @Test func aFailureThatIsNotAboutPermissionsKeepsListening() async throws {
        let center = makeCenter()
        let snippets: @Sendable (String) async -> ExpansionResult = { keyword in
            keyword == ";sig" ? .insert(Expansion("Best,", charactersAfterCursor: 0)) : .ignore
        }
        #expect(await center.start(keywords: [";sig"], options: ExpansionOptions(), expand: snippets) == .running)
        poster.failure = CGEventKeystrokePoster.eventUnavailable
        source.type(";sig")
        try await waitUntil { poster.refused.count == 1 }
        poster.failure = nil
        source.type(" ;sig")
        try await waitUntil { poster.posted.count == 5 }
        #expect(poster.posted == Keystroke.deletes(4) + [.text("Best,")])
        #expect(source.stopCount == 0)
        await center.stop()
    }
}
