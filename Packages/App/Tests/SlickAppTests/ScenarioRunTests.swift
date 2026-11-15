import AppKit
import Foundation
import Host
import Kit
import LauncherUI
import Root
import Testing

@testable import SlickApp

/// Every committed scenario, run headless: the real panel placed far off every screen, never key,
/// with a stand-in capture. `make scenario` runs the same files on screen with real captures.
@Suite("Committed scenarios", .serialized)
struct ScenarioRunTests {
    static let offscreen = CGRect(x: -20000, y: -20000, width: 1600, height: 1000)

    nonisolated static var folder: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../scenarios")
            .standardizedFileURL
    }

    nonisolated static var files: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    @Test(arguments: files)
    func passes(name: String) async throws {
        var file = try ScenarioMode.load(Data(contentsOf: Self.folder.appending(path: name)))
        // A capture with the key look would make the panel key and take the keyboard for a moment.
        file.items = file.items.map { item in
            if case .host(.capture(let captureName, _)) = item { return .host(.capture(name: captureName, key: false)) }
            return item
        }
        let data = FileManager.default.temporaryDirectory.appending(path: "app-scenario-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = NSApplication.shared
        let surface = LauncherSurface(visibleFrame: Self.offscreen)
        surface.accessibilityOverride = DisplayAccessibility(reduceMotion: true)
        let assembly = Assembly(
            .init(
                environment: .scenario, dataRoot: data, workspace: { RecordingWorkspace(wrapping: $0) },
                surface: surface))
        await assembly.start(prewarm: true)
        let panel = try #require(assembly.panel)
        #expect(await SelfTest.within(.seconds(20)) { await assembly.root.ready() })
        let runner = ScenarioRunner(panel: panel, output: data.appending(path: "output"), placesInCorner: false)
        runner.capture = { _ in Self.solidImage() }
        runner.log = { _ in }
        var lines: [String] = []
        let result = await ScenarioMode.run(file, runner: runner, assembly: assembly) { lines.append($0) }
        #expect(result.passed, "\(result.reason ?? "")\n\(lines.joined(separator: "\n"))")
        await assembly.shutdown()
    }

    nonisolated static func solidImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context?.makeImage() else { fatalError("cannot make a 4x4 image") }
        return image
    }
}
