import AppKit
import Testing

@testable import LauncherUI

/// When Large Type goes away, first as rules, then through the window's own event methods. The
/// window is never shown: events are made locally and handed to it directly.
@Suite("Large Type: dismissal", .timeLimit(.minutes(1)))
@MainActor struct LargeTypeDismissalTests {
    @Test(arguments: [
        LargeTypeDismissal.Event.keyDown(isRepeat: false), .click, .resignedKey, .appResignedActive,
    ])
    func eachEventHidesItOnce(event: LargeTypeDismissal.Event) {
        let dismissal = LargeTypeDismissal()
        var hides = 0
        dismissal.onDismiss = { hides += 1 }
        #expect(!dismissal.handle(event), "nothing to hide before it shows")
        dismissal.shown()
        #expect(dismissal.handle(event))
        #expect(!dismissal.isShown)
        #expect(!dismissal.handle(event))
        #expect(hides == 1)
    }

    @Test func aHeldKeysRepeatsDoNotHideIt() {
        let dismissal = LargeTypeDismissal()
        var hides = 0
        dismissal.onDismiss = { hides += 1 }
        dismissal.shown()
        #expect(!dismissal.handle(.keyDown(isRepeat: true)))
        #expect(dismissal.isShown)
        #expect(dismissal.handle(.keyDown(isRepeat: false)))
        #expect(hides == 1)
    }

    @Test func resetHidesWithoutTellingAnyone() {
        let dismissal = LargeTypeDismissal()
        var hides = 0
        dismissal.onDismiss = { hides += 1 }
        dismissal.shown()
        dismissal.reset()
        #expect(!dismissal.isShown)
        #expect(hides == 0)
    }

    // MARK: The window's event methods

    private static func key(_ characters: String, code: UInt16, repeating: Bool = false, command: Bool = false)
        -> NSEvent
    {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating,
            keyCode: code)!
    }

    private static func click(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func theWindowHidesOnEveryKindOfInputAndNotOnARepeat() {
        _ = NSApplication.shared
        let window = LargeTypeWindow()
        var hides = 0
        window.onHide = { hides += 1 }

        window.dismissal.shown()
        window.keyDown(with: Self.key("l", code: 37, repeating: true, command: true))
        #expect(hides == 0)
        window.keyDown(with: Self.key("a", code: 0))
        #expect(hides == 1)

        window.dismissal.shown()
        #expect(window.performKeyEquivalent(with: Self.key("q", code: 12, command: true)))
        #expect(hides == 2, "a command chord hides it and goes no further")

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            window.dismissal.shown()
            switch type {
            case .leftMouseDown: window.mouseDown(with: Self.click(type))
            case .rightMouseDown: window.rightMouseDown(with: Self.click(type))
            default: window.otherMouseDown(with: Self.click(type))
            }
        }
        #expect(hides == 5)

        window.dismissal.shown()
        window.resignKey()
        #expect(hides == 6)

        window.dismissal.shown()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(hides == 7)

        window.dismissal.shown()
        window.cancelOperation(nil)
        #expect(hides == 8)

        // Hidden already: nothing more happens, and a chord goes on as usual.
        window.keyDown(with: Self.key("a", code: 0))
        window.hide()
        #expect(hides == 8)
        #expect(!window.isVisible)
    }

    @Test func aClickOnTheTextReachesTheWindow() {
        _ = NSApplication.shared
        let window = LargeTypeWindow()
        var hides = 0
        window.onHide = { hides += 1 }
        window.dismissal.shown()
        window.contentView?.mouseDown(with: Self.click(.leftMouseDown))
        #expect(hides == 1)
    }
}
