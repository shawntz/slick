import AppKit
import Foundation
import Testing

@testable import Platform

/// Key focus in this app's own windows, from notifications posted on a private center. No window
/// is made.
@Suite(.timeLimit(.minutes(1))) struct OwnKeyFocusTests {
    @Test @MainActor func keyFocusFollowsTheKeyWindowNotifications() async throws {
        let notifications = NotificationCenter()
        let focus = OwnKeyFocus()
        let observer = OwnKeyFocusObserver(focus: focus, notifications: notifications)
        var changes = focus.changes().makeAsyncIterator()
        observer.start()
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(focus.isKey)
        #expect(await changes.next() != nil)
        // Another of this app's windows takes over: it resigns, then the next becomes key.
        notifications.post(name: NSWindow.didResignKeyNotification, object: nil)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(focus.isKey)
        notifications.post(name: NSWindow.didResignKeyNotification, object: nil)
        #expect(!focus.isKey)
        observer.stop()
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(!focus.isKey)
    }

    @Test func mergedSignalsRelayEitherStreamAndEndBoth() async throws {
        let first = FocusFeed()
        let second = FocusFeed()
        // The merged stream lives only inside the consumer, so it ends when the consumer is done.
        let consumer = Task {
            var count = 0
            for await _ in mergedSignals([first.stream(), second.stream()]) {
                count += 1
                if count == 2 { break }
            }
            return count
        }
        try await waitUntil { first.listenerCount == 1 && second.listenerCount == 1 }
        first.send()
        second.send()
        #expect(await boundedValue(of: consumer) == 2)
        try await waitUntil { first.listenerCount == 0 && second.listenerCount == 0 }
    }

    /// The paste waits until a keystroke would reach another app.
    @Test func aPasteGoesAheadOnlyWhenAnotherAppWouldGetTheKeystroke() {
        #expect(LivePasteboard.isReadyToPaste(frontmostProcessID: 20, ownProcessID: 10, ownWindowIsKey: false))
        #expect(!LivePasteboard.isReadyToPaste(frontmostProcessID: 20, ownProcessID: 10, ownWindowIsKey: true))
        #expect(!LivePasteboard.isReadyToPaste(frontmostProcessID: 10, ownProcessID: 10, ownWindowIsKey: false))
        #expect(!LivePasteboard.isReadyToPaste(frontmostProcessID: nil, ownProcessID: 10, ownWindowIsKey: false))
    }
}
