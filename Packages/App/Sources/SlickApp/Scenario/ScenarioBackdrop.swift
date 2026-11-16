import AppKit

/// A busy backdrop shown behind the panel during a scenario capture, so the glass has something
/// to refract: saturated diagonal stripes and black and white discs. It never takes key status and
/// lets clicks through. LauncherUITesting has a fuller one; the app draws its own so the release
/// binary does not link test support and the video frameworks it needs.
///
/// The picture is drawn when the window is made, before anything orders it in, and becomes its
/// content view's layer contents. So the window has its picture the moment it orders in, and a
/// capture taken then never shows the Mac's desktop through an empty window.
final class ScenarioBackdrop: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hasShadow = false
        level = .floating
        let view = BackdropView(frame: CGRect(origin: .zero, size: frame.size))
        contentView = view
        view.drawPicture(scale: backingScaleFactor)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The view that holds the picture as its layer's contents.
    final class BackdropView: NSView {
        /// The picture at the window's scale, drawn once.
        private(set) var picture: CGImage?

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var wantsUpdateLayer: Bool { true }

        /// AppKit asks again when it displays the view; the answer is the picture drawn already.
        override func updateLayer() {
            layer?.contents = picture
        }

        /// Draws the picture for the view's size at `scale` and sets it as the layer's contents.
        func drawPicture(scale: CGFloat) {
            picture = Self.render(size: bounds.size, scale: scale, appearance: effectiveAppearance)
            guard let layer else { return }
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.contents = picture
        }

        /// The picture as a bitmap of `size` points at `scale`, its system colors in `appearance`.
        static func render(size: CGSize, scale: CGFloat, appearance: NSAppearance) -> CGImage? {
            let width = Int((size.width * scale).rounded())
            let height = Int((size.height * scale).rounded())
            guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            appearance.performAsCurrentDrawingAppearance {
                draw(in: CGRect(origin: .zero, size: size))
            }
            NSGraphicsContext.current = previous
            return context.makeImage()
        }

        /// Stripes in eight colors across the whole area, then four discs on its diagonal: black,
        /// white, black, white, from the top left.
        static func draw(in bounds: CGRect) {
            let colors: [NSColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                .systemPurple, .white,
            ]
            let stripe: CGFloat = 36
            let span = bounds.width + bounds.height
            var index = 0
            var x = -bounds.height
            while x < span {
                colors[index % colors.count].setFill()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x, y: 0))
                path.line(to: CGPoint(x: x + stripe, y: 0))
                path.line(to: CGPoint(x: x + stripe + bounds.height, y: bounds.height))
                path.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
                path.close()
                path.fill()
                x += stripe
                index += 1
            }
            for (offset, color) in discs {
                color.setFill()
                let size = bounds.height * 0.18
                let center = CGPoint(x: bounds.width * offset, y: bounds.height * (1 - offset))
                NSBezierPath(
                    ovalIn: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
                ).fill()
            }
        }

        /// Where each disc sits along the diagonal, as a fraction of the width from the left and of
        /// the height from the top, and its color.
        static let discs: [(CGFloat, NSColor)] = [(0.1, .black), (0.35, .white), (0.6, .black), (0.85, .white)]
    }
}
