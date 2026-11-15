import AppKit
import LauncherUI
import LauncherUITesting

/// Measures pixel noise in flat areas that different views draw, as the window server shows
/// them: a flat image in a grid tile, a Markdown code block in the detail text view, and the
/// list's fill lens. Then forces 8-bit backing stores on the grid's and the text view's layers
/// and measures again.
///
///   noise [idle=15]
///
/// AppKit gives a drawn view a backing store whose depth it picks from what was drawn. A deeper
/// store reaches the screen through a dither, which shows as noise of about one level.
enum NoiseMode {
    struct Sample {
        let view: String
        let forced: Bool
        let deviation: Double
        let levels: Int
    }

    static func run(_ options: DemoOptions) async -> Bool {
        let idle = options.double("idle", 15)
        out = options.outputDirectory
        let deadline = Date().addingTimeInterval(options.double("idleBudget", 1800))
        let scene = DemoScene()
        scene.summoner.prewarm()
        await CaptureSupport.setAppearance(.darkAqua, scene)
        let frame = scene.windowFrame
        let backdrop = ShowcaseBackdropWindow(frame: frame)
        backdrop.show(flatImage(gray: 0.35, size: 8))

        let grid = GridView()
        let split = ListDetailView()
        let flat = flatImage(gray: 0.62, size: 256)
        let markdown = "Code:\n\n```\nlet value = 1\nlet other = 2\nlet third = 3\n```\n"
        var samples: [Sample] = []
        for forced in [false, true] {
            guard await IdleGate.wait(seconds: idle, until: deadline) else { return false }
            backdrop.orderFrontRegardless()
            backdrop.order(.below, relativeTo: scene.surface.panel.windowNumber)
            let started = Date()

            scene.surface.theme.lens.style = .fill
            scene.surface.setContent(scene.list, animated: false)
            scene.show(query: "co")
            if let image = await CaptureSupport.captureKey(scene), let row = scene.list.rowRect(0) {
                // A strip of the lens above the row's text.
                let strip = CGRect(x: row.midX - 100, y: row.minY + 2, width: 200, height: 4)
                let rect = pixels(strip, in: scene.list, scene: scene, image: image)
                samples.append(measure("list fill lens", forced, image, rect))
            }
            scene.surface.theme.lens.style = Theme.standard.lens.style

            scene.surface.setContent(grid, animated: false)
            // The second pass draws the image already in the window's colour space.
            if forced { forceEightBit(grid) }
            grid.apply(
                GridContent(
                    sections: [
                        GridSection(
                            cells: (0..<5).map { GridCell(id: UInt64($0), content: .image(flat), title: "Flat \($0)") })
                    ], columns: .image, aspectRatio: 1.5))
            grid.select(nil, animated: false)
            if let image = await CaptureSupport.captureKey(scene), let cell = grid.cellRect(1) {
                // The middle of the picture in the second tile.
                let middle = CGPoint(x: cell.midX, y: cell.minY + cell.width / 3)
                let rect = pixels(
                    CGRect(x: middle.x - 25, y: middle.y - 25, width: 50, height: 50), in: grid, scene: scene,
                    image: image)
                samples.append(measure("grid image", forced, image, rect))
            }

            scene.surface.setContent(split, animated: false)
            split.list.apply(scene.catalog.content(for: "co", limit: 9))
            split.detail.apply(DetailContent(body: .markdown(markdown)))
            if forced { forceEightBit(split.detail) }
            if let image = await CaptureSupport.captureKey(scene), let block = codeBlockRect(split.detail) {
                let rect = pixels(block.insetBy(dx: 6, dy: 4), in: split.detail, scene: scene, image: image)
                samples.append(measure("detail code block", forced, image, rect))
            }
            backdrop.orderOut(nil)
            say("noise: batch on screen \(format(Date().timeIntervalSince(started), 2)) s")
            scene.surface.setContent(scene.list, animated: false)
            await pause(ms: 700)
        }
        backdrop.close()
        var table = TextTable(["view", "8-bit forced", "std dev (levels)", "distinct colours"])
        for sample in samples {
            table.add([sample.view, sample.forced ? "yes" : "no", format(sample.deviation, 3), "\(sample.levels)"])
        }
        say(table.render())
        return samples.count == 6
    }

    /// Sets every AppKit backing layer under `view` to an 8-bit store.
    static func forceEightBit(_ view: NSView) {
        var layers = view.layer.map { [$0] } ?? []
        var count = 0
        while let layer = layers.popLast() {
            if layer.contentsFormat != .RGBA8Uint {
                layer.contentsFormat = .RGBA8Uint
                count += 1
            }
            layers += layer.sublayers ?? []
        }
        view.needsDisplay = true
        for sub in view.subviews { sub.needsDisplay = true }
        view.displayIfNeeded()
        say("noise: forced \(count) layers under \(type(of: view)) to RGBA8")
    }

    static func codeBlockRect(_ pane: DetailPane) -> CGRect? {
        let textView = pane.descendantTextView
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return nil }
        let range = (textView.string as NSString).range(of: "let value")
        guard range.location != NSNotFound else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x + rect.width + 30
        rect.origin.y += textView.textContainerOrigin.y
        rect.size.width = 80
        return pane.convert(rect, from: textView)
    }

    static func pixels(_ rect: CGRect, in view: NSView, scene: DemoScene, image: CGImage) -> CGRect {
        let window = view.convert(rect, to: nil)
        let scale = CGFloat(image.width) / scene.windowFrame.width
        return CGRect(
            x: window.minX * scale, y: (scene.windowFrame.height - window.maxY) * scale, width: window.width * scale,
            height: window.height * scale)
    }

    nonisolated(unsafe) static var out: URL?

    static func measure(_ name: String, _ forced: Bool, _ image: CGImage, _ rect: CGRect) -> Sample {
        if let out {
            let base = "\(name.replacingOccurrences(of: " ", with: "-"))-\(forced ? "forced" : "auto")"
            try? SheetComposer.writePNG(image, to: out.appendingPathComponent("\(base).png"))
        }
        guard let crop = image.cropping(to: rect.integral),
            let context = CGContext(
                data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Sample(view: name, forced: forced, deviation: .nan, levels: 0) }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var values: [Double] = []
        var levels = Set<UInt32>()
        for index in 0..<(crop.width * crop.height) {
            let red = bytes[index * 4]
            let green = bytes[index * 4 + 1]
            let blue = bytes[index * 4 + 2]
            values.append(0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue))
            levels.insert(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
        }
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, values.count))
        return Sample(view: name, forced: forced, deviation: variance.squareRoot(), levels: levels.count)
    }

    static func flatImage(gray: CGFloat, size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: gray, green: gray * 0.9, blue: gray * 1.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}

extension NSView {
    /// The first `NSTextView` under this view.
    var descendantTextView: NSTextView? {
        for sub in subviews {
            if let text = sub as? NSTextView { return text }
            if let found = sub.descendantTextView { return found }
        }
        return nil
    }
}
