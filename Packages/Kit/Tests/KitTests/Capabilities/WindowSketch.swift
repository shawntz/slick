import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

/// What the window feature needs from the system. It lives in the feature's own package with a live
/// Accessibility implementation and this fake, because no other feature needs it.
nonisolated protocol WindowMover: Sendable {
    func move(to frame: WindowFraction) async throws
}

nonisolated struct WindowFraction: Hashable, Sendable {
    var x: Double
    var width: Double
}

nonisolated final class RecordingMover: WindowMover {
    private let moves = Mutex<[WindowFraction]>([])
    var recorded: [WindowFraction] { moves.withLock { $0 } }
    func move(to frame: WindowFraction) async throws { moves.withLock { $0.append(frame) } }
}

/// How the feature finds its mover in each kind of run, so it never branches on the environment.
/// The app's live mover uses Accessibility; this sketch has none, so both record.
nonisolated enum WindowMoverKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any WindowMover { RecordingMover() }
    static func isolated(_ context: FeatureContext) -> any WindowMover { RecordingMover() }
}

/// Scenario 2, window management: many no-view commands from a table, hotkeys the user assigns,
/// cycling through sizes when the same command repeats quickly, a HUD after each, and a graceful
/// path when Accessibility is missing (the host shows its card instead of running the command).
final class WindowSketch: Feature {
    static let manifest = FeatureManifest(
        id: "window-management", name: "Window Management", icon: .symbol("rectangle.split.2x1"),
        permissions: [PermissionNeed(.accessibility, reason: "Move and resize the frontmost window.")])

    /// Each command and the sizes it cycles through on repeated presses.
    static let table: [(id: String, title: String, steps: [WindowFraction])] = [
        (
            "left-half", "Left Half",
            [
                WindowFraction(x: 0, width: 0.5), WindowFraction(x: 0, width: 1.0 / 3),
                WindowFraction(x: 0, width: 2.0 / 3),
            ]
        ),
        ("right-half", "Right Half", [WindowFraction(x: 0.5, width: 0.5)]),
        ("maximize", "Maximize", [WindowFraction(x: 0, width: 1)]),
    ]

    private let context: FeatureContext
    private let mover: any WindowMover
    private var last: (command: String, at: Date, step: Int)?

    init(context: FeatureContext) {
        self.context = context
        self.mover = context.service(WindowMoverKey.self)
    }

    /// Runs are serial by default, so a second press always sees the step the first one chose.
    var commands: [Command] {
        Self.table.map { entry in
            Command(id: entry.id, title: entry.title, icon: .symbol("macwindow"), requires: [.accessibility]) { _ in
                let step = self.nextStep(for: entry.id, count: entry.steps.count)
                try await self.mover.move(to: entry.steps[step])
                return .close(hud: HUD(entry.title))
            }
        }
    }

    /// Shortcuts another window manager uses, applied in one step from settings.
    var hotkeyPresets: [HotkeyPreset] {
        [
            HotkeyPreset(
                id: "arrows", name: "Control-Option Arrows",
                bindings: [
                    "left-half": KeyCombo(.leftArrow, [.control, .option]),
                    "right-half": KeyCombo(.rightArrow, [.control, .option]),
                    "maximize": KeyCombo(.return, [.control, .option]),
                ])
        ]
    }

    private func nextStep(for command: String, count: Int) -> Int {
        let now = context.clock.now
        var step = 0
        if let last, last.command == command, now.timeIntervalSince(last.at) < 1.5 {
            step = (last.step + 1) % count
        }
        last = (command, now, step)
        return step
    }
}

@Suite("Scenario: window management")
struct WindowSketchTests {
    @Test func cyclesOnRepeatedPressesAndShowsAHUD() async throws {
        let mover = RecordingMover()
        let fakes = FakeServices()
        fakes.override(WindowMoverKey.self, with: mover)
        let harness = FeatureHarness(WindowSketch.self, fakes: fakes)
        #expect(harness.issues.isEmpty)
        #expect(harness.feature.commands.allSatisfy { $0.suggestedHotkey == nil }, "the user assigns hotkeys")
        for _ in 0..<3 {
            try await harness.run("left-half", launch: .hotkey)
            harness.fakes.clock.advance(by: .milliseconds(500))
        }
        harness.fakes.clock.advance(by: .seconds(2))
        try await harness.run("left-half", launch: .hotkey)
        #expect(mover.recorded.map(\.width) == [0.5, 1.0 / 3, 2.0 / 3, 0.5])
        #expect(harness.huds == Array(repeating: "Left Half", count: 4))
    }

    @Test func missingAccessibilityStopsBeforeAnythingMoves() async throws {
        let harness = FeatureHarness(WindowSketch.self, fakes: FakeServices(permissions: .notDetermined))
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await harness.run("maximize", launch: .hotkey)
        }
        #expect(harness.fakes.permissions.requests.isEmpty)
    }
}
