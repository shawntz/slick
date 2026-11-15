import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// The lowest contrast ratios found in one capture, by kind of text. NaN where none was drawn.
struct ContrastSample {
    var title = Double.nan
    var dimmedTitle = Double.nan
    var selectedTitle = Double.nan
    var subtitle = Double.nan
    var accessory = Double.nan
    var header = Double.nan
    var capsule = Double.nan

    /// Titles need 4.5:1; subtitles, accessories and headers 3:1 (glass rule 5).
    var passes: Bool {
        let titles = [title, dimmedTitle, selectedTitle].filter(\.isFinite)
        let secondary = [subtitle, accessory, header, capsule].filter(\.isFinite)
        return titles.allSatisfy { $0 >= 4.5 } && secondary.allSatisfy { $0 >= 3 }
    }

    var cells: [String] {
        [title, dimmedTitle, selectedTitle, subtitle, accessory, header, capsule].map { format($0, 1) } + [
            passes ? "pass" : "FAIL"
        ]
    }

    static let headers = ["title", "dim title", "selected", "subtitle", "accessory", "header", "tag/keycap", "rule 5"]
}

/// Puts a scene on screen over a backdrop, captures it with key status, and measures contrast.
enum CaptureSupport {
    /// Runs `body` with a backdrop window of `kind` right under the panel, then removes it.
    static func withBackdrop<T>(_ kind: BackdropKind, under scene: DemoScene, _ body: @MainActor () async -> T) async
        -> T
    {
        let backdrop = BackdropWindow(kind: kind, frame: scene.windowFrame)
        backdrop.orderFrontRegardless()
        backdrop.order(.below, relativeTo: scene.surface.panel.windowNumber)
        defer { backdrop.close() }
        return await body()
    }

    /// Switches the panel's appearance. The glass material finishes changing only once it has
    /// been on screen for a moment, so the panel is shown briefly without key status first.
    static func setAppearance(_ name: NSAppearance.Name, _ scene: DemoScene) async {
        scene.surface.panel.appearance = NSAppearance(named: name)
        scene.surface.refreshTheme()
        scene.summoner.takesKeyStatus = false
        scene.summoner.summon()
        await pause(ms: 500)
        scene.summoner.dismiss(returnFocus: false)
        await pause(ms: 100)
    }

    /// Shows the panel with key status (the glass's full look), captures it and hides it again.
    /// Key status is held for about a quarter of a second.
    static func captureKey(_ scene: DemoScene, settle: Double = 140) async -> CGImage? {
        scene.summoner.takesKeyStatus = true
        scene.summoner.summon()
        scene.surface.updateHeight(animated: false)
        await pause(ms: settle)
        let image = try? await OwnWindowCapture.capture(scene.windowFrame)
        scene.summoner.dismiss(returnFocus: true)
        return image
    }

    /// The contrast of every kind of text the list and the field draw, in a capture of the window.
    /// `list` is the scene's own list unless another one shows, as beside a detail pane.
    static func measure(_ image: CGImage, scene: DemoScene, list: ResultListView? = nil) -> ContrastSample {
        let list = list ?? scene.list
        let scale = CGFloat(image.width) / scene.windowFrame.width
        func pixels(_ rect: CGRect, in view: NSView) -> CGRect {
            let window = view.convert(rect, to: nil)
            let height = scene.windowFrame.height
            return CGRect(
                x: window.minX * scale, y: (height - window.maxY) * scale, width: window.width * scale,
                height: window.height * scale
            )
            .insetBy(dx: -1 * scale, dy: 0)
        }
        func ratio(_ rect: CGRect) -> Double { ContrastMeter.contrastRatio(image, in: pixels(rect, in: list)) }
        var sample = ContrastSample()
        let viewport = list.preferredContentHeight(limit: 10_000)
        for index in 0..<list.content.rowCount {
            guard let rect = list.rowRect(index), rect.minY >= 0, rect.maxY <= viewport,
                let frames = list.textFrames(row: index)
            else { continue }
            if index == list.selectedRow {
                sample.selectedTitle = min(sample.selectedTitle, ratio(frames.title))
                continue
            }
            sample.title = min(sample.title, ratio(frames.title))
            if let dimmed = frames.dimmedTitle { sample.dimmedTitle = min(sample.dimmedTitle, ratio(dimmed)) }
            if let subtitle = frames.subtitle { sample.subtitle = min(sample.subtitle, ratio(subtitle)) }
            for accessory in frames.accessories { sample.accessory = min(sample.accessory, ratio(accessory)) }
            for capsule in frames.capsules { sample.capsule = min(sample.capsule, ratio(capsule)) }
        }
        for header in list.headerTextFrames() { sample.header = min(sample.header, ratio(header)) }
        return sample
    }
}

/// `min` that treats NaN as "nothing yet".
private func min(_ a: Double, _ b: Double) -> Double {
    a.isNaN ? b : (b.isNaN ? a : Swift.min(a, b))
}
