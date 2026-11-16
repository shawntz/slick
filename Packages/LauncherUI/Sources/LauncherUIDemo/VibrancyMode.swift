import AppKit
import LauncherUI
import LauncherUITesting

/// Asks whether the glass gives vibrancy to secondary text drawn into a template image and shown
/// by an `NSImageView`, compared with a vibrant `NSTextField` label and with Core Text. Prints the
/// compositing filter each one gets, the contrast of each over every backdrop, and the main-thread
/// cost of producing nine template images.
enum VibrancyMode {
    /// Three copies of the same secondary text, one per technique, stacked in the content area.
    final class ProbeContent: NSView, LauncherContentView {
        var selectionLens: SelectionLens?
        var contentHeightDidChange: (() -> Void)?
        let label = NSTextField(labelWithString: VibrancyMode.text)
        let imageView = NSImageView()
        private var theme: ResolvedTheme?

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            label.textColor = .secondaryLabelColor
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = .secondaryLabelColor
            addSubview(label)
            addSubview(imageView)
        }

        required init?(coder: NSCoder) { nil }

        func preferredContentHeight(limit: CGFloat) -> CGFloat { 3 * VibrancyMode.rowHeight + 16 }

        func apply(_ theme: ResolvedTheme) {
            self.theme = theme
            label.font = theme.theme.fonts.subtitle.nsFont
            imageView.image = VibrancyMode.templateImage(font: label.font ?? .systemFont(ofSize: 13))
            let size = imageView.image?.size ?? .zero
            label.frame = frame(row: 0, height: ceil(label.intrinsicContentSize.height))
            imageView.frame = CGRect(
                x: VibrancyMode.textX, y: 8 + 2 * VibrancyMode.rowHeight + (VibrancyMode.rowHeight - size.height) / 2,
                width: size.width, height: size.height)
            needsDisplay = true
        }

        func frame(row: Int, height: CGFloat) -> CGRect {
            CGRect(
                x: VibrancyMode.textX - 2,
                y: 8 + CGFloat(row) * VibrancyMode.rowHeight + (VibrancyMode.rowHeight - height) / 2,
                width: 300, height: height)
        }

        /// The Core Text copy, in the middle row.
        override func draw(_ dirtyRect: NSRect) {
            guard let theme, let context = NSGraphicsContext.current?.cgContext else { return }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: VibrancyMode.text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): theme.subtitleFont,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): theme.subtitle,
                    ]))
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: VibrancyMode.textX, y: 8 + VibrancyMode.rowHeight * 1.5 + 4.5)
            CTLineDraw(line, context)
        }

        /// The text box of each technique, in view coordinates: label, Core Text, image.
        var textBoxes: [CGRect] {
            let coreText = CGRect(x: VibrancyMode.textX, y: 8 + VibrancyMode.rowHeight * 1.5 - 8, width: 80, height: 16)
            return [label.frame.insetBy(dx: 2, dy: 0), coreText, imageView.frame]
        }
    }

    static let text = "Application Command"
    static let rowHeight: CGFloat = 44
    static let textX: CGFloat = 56

    /// The text drawn in black into a template image, so the image view tints it.
    static func templateImage(font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func run(_ options: DemoOptions) async -> Bool {
        let scene = DemoScene()
        let probe = ProbeContent()
        scene.surface.setContent(probe, animated: false)
        scene.summoner.prewarm()
        var table = TextTable(["appearance", "backdrop", "NSTextField label", "Core Text", "template NSImageView"])
        var filters: [String] = []
        for (name, appearance) in ShotsMode.appearances {
            await CaptureSupport.setAppearance(appearance, scene)
            for backdrop in BackdropKind.matrix {
                let ratios = await CaptureSupport.withBackdrop(backdrop, under: scene) { () async -> [Double] in
                    scene.summoner.takesKeyStatus = true
                    scene.summoner.summon()
                    scene.surface.updateHeight(animated: false)
                    await pause(ms: 140)
                    if filters.isEmpty { filters = compositingFilters(probe) }
                    let image = try? await OwnWindowCapture.capture(scene.windowFrame)
                    scene.summoner.dismiss(returnFocus: true)
                    guard let image else { return [] }
                    let scale = CGFloat(image.width) / scene.windowFrame.width
                    return probe.textBoxes.map { box in
                        let rect = probe.convert(box, to: nil)
                        let pixels = CGRect(
                            x: rect.minX * scale, y: (scene.windowFrame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale)
                        return ContrastMeter.contrastRatio(image, in: pixels)
                    }
                }
                table.add([name, backdrop.rawValue] + ratios.map { format($0, 1) })
                await pause(ms: 500)
            }
        }
        say("Compositing filters inside the glass:")
        for line in filters { say("  \(line)") }
        say("Contrast of the same secondary text, three ways:")
        say(table.render())

        let font = NSFont.systemFont(ofSize: 13)
        var samples: [Double] = []
        let views = (0..<9).map { _ in NSImageView() }
        for _ in 0..<120 {
            let start = LatencyClock.now()
            for view in views { view.image = templateImage(font: font) }
            samples.append(LatencyClock.ms(start, LatencyClock.now()))
        }
        say("nine template images built and assigned (ms): \(LatencySummary(Array(samples.dropFirst(20))))")
        return !filters.isEmpty
    }

    /// The compositing filter of every layer under `view` that has one, by view class.
    static func compositingFilters(_ view: NSView) -> [String] {
        var lines: [String] = []
        func visit(_ view: NSView) {
            var layers: [CALayer] = []
            if let layer = view.layer { layers = [layer] + (layer.sublayers ?? []) }
            let found = layers.compactMap { $0.compositingFilter.map { "\($0)" } }
            lines.append("\(type(of: view)): \(found.isEmpty ? "none" : found.joined(separator: ", "))")
            view.subviews.forEach(visit)
        }
        visit(view)
        return lines
    }
}
