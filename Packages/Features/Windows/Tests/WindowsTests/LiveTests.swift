import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import Windows

/// Checks against the real Mac. Neither test touches any window but one the test made itself, and
/// neither can raise a permission prompt.
@MainActor
@Suite("Live", .serialized, .timeLimit(.minutes(1)))
struct LiveTests {
    static let title = "Window Management Live Test"

    /// The live service's display list, flipped from AppKit, matches Core Graphics, which reports
    /// displays in the Accessibility space already. Read-only.
    @Test func displaysFlipIntoTheSpaceCoreGraphicsUses() {
        for display in AccessibilityWindows.displays() {
            let bounds = Frame(CGDisplayBounds(display.id))
            #expect(display.frame.isClose(to: bounds, tolerance: 0.5), "display \(display.id): \(display.frame)")
            #expect(contains(display.frame, display.visibleFrame), "display \(display.id)")
            #expect(display.scale >= 1)
        }
    }

    /// Moves a window this test made, invisible at alpha 0, through the same Accessibility code the
    /// live service uses, then closes it. It never looks at the frontmost app or any other window.
    ///
    /// It runs only with `WINDOWS_LIVE_TEST=1`. A process answers Accessibility requests for itself
    /// only once it has finished launching as an app. A plain test process does not, and finishing
    /// the launch here could activate it and take the keyboard from the person at the Mac. So under
    /// `swift test` the test cancels itself with that reason.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WINDOWS_LIVE_TEST"] == "1"))
    func movesAndResizesItsOwnWindow() throws {
        let answers = try runWhileAccessibilityAsks { process -> Bool in
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(process), kAXRoleAttribute as CFString, &role)
            return error != .notImplemented
        }
        if !answers {
            try Test.cancel("This process does not answer Accessibility for itself until it finishes launching.")
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let main = try #require(AccessibilityWindows.displays().first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        // Ordering in does not activate this process, so the keyboard stays where it was.
        window.orderFrontRegardless()
        defer { window.close() }

        let target = Frame(x: main.visibleFrame.minX + 120, y: main.visibleFrame.minY + 90, width: 320, height: 210)
        let title = Self.title
        let moved = try runWhileAccessibilityAsks { process -> (Frame, WindowState?)? in
            let app = AXElement.application(process)
            guard
                let element = try app.elements(kAXWindowsAttribute).first(where: {
                    (try? $0.string(kAXTitleAttribute)) == title
                })
            else { return nil }
            let state = try AccessibilityWindows.state(of: element, process: process)
            return (try element.setFrame(target, canResize: state?.canResize ?? false, app: app), state)
        }
        let (readBack, state) = try #require(moved)
        #expect(state?.canMove == true && state?.canResize == true)
        #expect(readBack.isClose(to: target, tolerance: 1), "read back \(readBack)")

        // AppKit agrees, once its frame is flipped into the Accessibility space.
        let appKit = Frame(window.frame)
        let flipped = Frame(x: appKit.x, y: main.frame.height - appKit.maxY, width: appKit.width, height: appKit.height)
        #expect(flipped.isClose(to: target, tolerance: 1), "AppKit sees \(flipped)")
    }

    /// Runs Accessibility work on a background thread while the main run loop keeps turning, since
    /// a process answers its own Accessibility requests there.
    private func runWhileAccessibilityAsks<Value: Sendable>(
        _ work: @escaping @Sendable (pid_t) throws -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let process = ProcessInfo.processInfo.processIdentifier
        Thread.detachNewThread { box.finish(Result { try work(process) }) }
        let deadline = Date().addingTimeInterval(10)
        while box.outcome == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let outcome = box.outcome else { throw WindowError.refused }
        return try outcome.get()
    }
}

/// Hands a result from the worker thread to the test.
private nonisolated final class ResultBox<Value: Sendable>: @unchecked Sendable {
    // The lock guards the one stored result.
    private let lock = NSLock()
    private var result: Result<Value, any Error>?

    var outcome: Result<Value, any Error>? { lock.withLock { result } }

    func finish(_ outcome: Result<Value, any Error>) {
        lock.withLock { result = outcome }
    }
}
