import AppKit
import Foundation
import Host
import LauncherUI
import LauncherUITesting

/// Runs a scenario file against the demo world, with a busy backdrop behind captures.
@MainActor enum ScenarioMode {
    static func run(file: String?, out: URL) async -> Bool {
        guard let file else {
            say("scenario needs file=<path>")
            return false
        }
        let world = await DemoWorld()
        defer { world.panel.surface.panel.close() }
        let runner = ScenarioRunner(panel: world.panel, output: out)
        runner.makeBackdrop = { frame in BackdropWindow(kind: .busy, frame: frame) }
        runner.capture = { try await OwnWindowCapture.capture($0) }
        return await runner.run(file: URL(fileURLWithPath: file))
    }
}
