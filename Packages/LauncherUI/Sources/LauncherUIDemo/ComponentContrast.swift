import AppKit
@_spi(Testing) import LauncherUI
import LauncherUITesting

/// Measures the contrast of the text a component draws, in a capture of the panel or the HUD.
/// Titles, values and body text are held to 4.5:1; labels, hints, messages, headers and capsules
/// to 3:1 (glass rule 5).
enum ComponentContrast {
    static func measure(_ state: String, image: CGImage, stage: ComponentStage) -> ContrastSample {
        let surface = stage.surface
        let window = stage.scene.windowFrame
        let scale = CGFloat(image.width) / window.width
        var sample = ContrastSample()

        func ratio(_ rect: CGRect, in view: NSView) -> Double {
            let inWindow = view.convert(rect, to: nil)
            let pixels = CGRect(
                x: inWindow.minX * scale, y: (window.height - inWindow.maxY) * scale, width: inWindow.width * scale,
                height: inWindow.height * scale)
            return ContrastMeter.contrastRatio(image, in: pixels.insetBy(dx: -scale, dy: 0))
        }
        func add(_ drawn: DrawnText, in view: NSView) {
            for rect in drawn.titles { sample.title = lowest(sample.title, ratio(rect, in: view)) }
            for rect in drawn.selectedTitles {
                sample.selectedTitle = lowest(sample.selectedTitle, ratio(rect, in: view))
            }
            for rect in drawn.secondary { sample.subtitle = lowest(sample.subtitle, ratio(rect, in: view)) }
            for rect in drawn.headers { sample.header = lowest(sample.header, ratio(rect, in: view)) }
            for rect in drawn.capsules { sample.capsule = lowest(sample.capsule, ratio(rect, in: view)) }
            for rect in drawn.messages { sample.accessory = lowest(sample.accessory, ratio(rect, in: view)) }
        }

        switch state {
        case "grid-glyph", "grid-image":
            add(stage.grid.drawnText(), in: stage.grid)
        case "detail-markdown", "detail-image", "filter-menu":
            merge(CaptureSupport.measure(image, scene: stage.scene, list: stage.split.list), into: &sample)
            add(stage.split.detail.drawnText(), in: stage.split.detail)
            if let menu = surface.overlay as? DropdownMenuView { add(menu.drawnText(), in: menu) }
        case "action-card":
            if let card = surface.overlay as? ActionCardView { add(card.drawnText(), in: card) }
        case "confirm-card":
            if let card = surface.overlay as? ConfirmCardView { add(card.drawnText(), in: card) }
        case "form":
            add(stage.form.drawnText(), in: stage.form)
        case "arguments":
            add(surface.queryField.drawnText(), in: surface.queryField)
        case "empty-loading":
            add(stage.empty.drawnText(), in: stage.empty)
        case "hud":
            guard let text = stage.hud.textScreenFrame else { break }
            let capture = stage.hud.frame.insetBy(dx: -60, dy: -40)
            let hudScale = CGFloat(image.width) / capture.width
            let pixels = CGRect(
                x: (text.minX - capture.minX) * hudScale, y: (capture.maxY - text.maxY) * hudScale,
                width: text.width * hudScale, height: text.height * hudScale)
            sample.title = ContrastMeter.contrastRatio(image, in: pixels)
        default:
            break
        }
        return sample
    }

    private static func merge(_ other: ContrastSample, into sample: inout ContrastSample) {
        sample.title = lowest(sample.title, other.title)
        sample.dimmedTitle = lowest(sample.dimmedTitle, other.dimmedTitle)
        sample.selectedTitle = lowest(sample.selectedTitle, other.selectedTitle)
        sample.subtitle = lowest(sample.subtitle, other.subtitle)
        sample.accessory = lowest(sample.accessory, other.accessory)
        sample.header = lowest(sample.header, other.header)
        sample.capsule = lowest(sample.capsule, other.capsule)
    }

    /// `min` that treats NaN as "nothing yet".
    private static func lowest(_ a: Double, _ b: Double) -> Double {
        a.isNaN ? b : (b.isNaN ? a : min(a, b))
    }
}
