import Testing

@testable import Windows

/// The one pass the services run, against the simulated desktop: plan, set, read back, and set
/// the position once more when the window refused the size.
@Suite("Arranging a window", .timeLimit(.minutes(1)))
struct ArrangerTests {
    func desktop(_ change: (inout SimulatedWindows.Window) -> Void = { _ in }) -> SimulatedWindows {
        var window = WindowsHarness.editor
        change(&window)
        return SimulatedWindows(displays: [Displays.laptop, Displays.rightExternal], windows: [window])
    }

    func moved(_ outcome: LayoutOutcome) throws -> Moved {
        guard case .moved(let moved) = outcome else {
            Issue.record("expected a move, got \(outcome)")
            throw WindowError.refused
        }
        return moved
    }

    @Test func aWindowTakesThePlannedFrameInOneSet() async throws {
        let desktop = desktop()
        let outcome = try await desktop.arrangeFocusedWindow(request(.half(.left)))
        let moved = try moved(outcome)
        #expect(moved.after == Frame(x: 0, y: 33, width: 756, height: 879))
        #expect(moved.before == WindowsHarness.editor.frame)
        #expect(moved.window == WindowsHarness.editor.ref.key)
        #expect(desktop.frameSets == 1)
    }

    @Test func aMinimumWidthKeepsALeftHalfAtTheLeftEdge() async throws {
        let desktop = desktop { $0.minimumSize = Size(width: 900, height: 300) }
        let left = try moved(await desktop.arrangeFocusedWindow(request(.half(.left))))
        #expect(left.after == Frame(x: 0, y: 33, width: 900, height: 879))
        let right = try moved(await desktop.arrangeFocusedWindow(request(.half(.right))))
        #expect(right.after == Frame(x: 612, y: 33, width: 900, height: 879))
        #expect(desktop.frameSets == 3, "the right half needed one more set to stay at the right edge")
    }

    @Test func aFixedSizeWindowMovesWithoutResizing() async throws {
        let desktop = desktop { $0.canResize = false }
        let moved = try moved(await desktop.arrangeFocusedWindow(request(.half(.left))))
        #expect(moved.after == Frame(x: 0, y: 222.5, width: 800, height: 500))
        #expect(desktop.frameSets == 2)
    }

    @Test func windowsThatCannotBeArrangedAreLeftAlone() async throws {
        let stuck = desktop { $0.canMove = false }
        #expect(try await stuck.arrangeFocusedWindow(request(.maximize)) == .unchanged(.cannotMove))
        let fullScreen = desktop { $0.isFullScreen = true }
        #expect(try await fullScreen.arrangeFocusedWindow(request(.maximize)) == .unchanged(.fullScreen))
        let minimized = desktop { $0.isMinimized = true }
        #expect(try await minimized.arrangeFocusedWindow(request(.maximize)) == .unchanged(.noWindow))
        for desktop in [stuck, fullScreen, minimized] {
            #expect(desktop.frameSets == 0)
        }
    }

    @Test func aRevokedPermissionThrows() async {
        let desktop = desktop()
        desktop.accessibilityGranted = false
        await #expect(throws: WindowError.accessibilityMissing) {
            try await desktop.arrangeFocusedWindow(request(.maximize))
        }
        await #expect(throws: WindowError.accessibilityMissing) { try await desktop.openWindows() }
        await #expect(throws: WindowError.accessibilityMissing) { try await desktop.toggleFullScreen() }
    }

    @Test func fullScreenTogglesAndRefusesWindowsWithoutIt() async throws {
        let desktop = desktop()
        #expect(try await desktop.toggleFullScreen() == .entered)
        #expect(try await desktop.toggleFullScreen() == .exited)
        let panel = self.desktop { $0.supportsFullScreen = false }
        #expect(try await panel.toggleFullScreen() == .unsupported)
        let empty = SimulatedWindows(displays: [Displays.laptop], windows: [])
        #expect(try await empty.toggleFullScreen() == .noWindow)
    }

    @Test func theSampleDesktopIsSyntheticAndUsable() async throws {
        let sample = SimulatedWindows.sample()
        #expect(sample.displays.count == 2)
        #expect(sample.windows.allSatisfy { $0.bundleID?.hasPrefix("com.example.") == true })
        let outcome = try await sample.arrangeFocusedWindow(request(.maximize))
        #expect(try moved(outcome).after == SimulatedWindows.sampleLaptop.visibleFrame)
    }

    @Test func windowReferencesRoundTripThroughRowKeys() {
        let refs = [WindowRef(process: 501, token: 7), WindowRef(process: 1, token: -9_223_372_036_854_775_807)]
        for ref in refs {
            #expect(WindowRef(key: ref.key) == ref)
        }
        #expect(WindowRef(key: "nonsense") == nil)
        #expect(WindowRef(key: "1_2_3") == nil)
    }
}
