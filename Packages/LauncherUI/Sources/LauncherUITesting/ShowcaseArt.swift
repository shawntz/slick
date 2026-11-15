import AppKit

/// Calm abstract pictures drawn in code for product shots: soft glows of colour over a gradient,
/// like a desktop wallpaper. Nothing is a photograph and nothing comes from a third party.
///
/// A picture is a ``Recipe``: a diagonal base gradient, then elliptical glows, then ribbons of
/// light, then a vignette. Positions and sizes are fractions of the picture, with y measured from
/// the top, so one recipe renders at any size and aspect.
public enum ShowcaseArt {
    /// A soft elliptical glow whose alpha falls off like a Gaussian.
    public struct Glow: Sendable {
        public var x: Double
        public var y: Double
        /// The radius as a fraction of the picture's longer side.
        public var radius: Double
        public var color: UInt32
        public var alpha: Double
        public var stretchX: Double
        public var stretchY: Double

        public init(
            _ x: Double, _ y: Double, radius: Double, _ color: UInt32, alpha: Double, stretchX: Double = 1,
            stretchY: Double = 1
        ) {
            self.x = x
            self.y = y
            self.radius = radius
            self.color = color
            self.alpha = alpha
            self.stretchX = stretchX
            self.stretchY = stretchY
        }
    }

    /// A band of soft light along a cubic curve, drawn as a chain of small glows.
    public struct Ribbon: Sendable {
        /// Start, two control points and end, as (x, y) fractions.
        public var points: [CGPoint]
        /// The band's half-width as a fraction of the picture's longer side.
        public var width: Double
        public var color: UInt32
        /// The alpha of each glow in the chain; they overlap about eight deep.
        public var alpha: Double
        /// Adds light instead of covering, for ribbons over dark pictures.
        public var additive: Bool

        public init(_ points: [CGPoint], width: Double, _ color: UInt32, alpha: Double, additive: Bool) {
            self.points = points
            self.width = width
            self.color = color
            self.alpha = alpha
            self.additive = additive
        }
    }

    /// A filled layer under a smooth wavy edge, like a dune, a hill or a swell of water.
    public struct Wave: Sendable {
        /// Where the edge sits, as a fraction from the top.
        public var level: Double
        /// The edge's swing, as a fraction of the picture's height.
        public var amplitude: Double
        /// Swings across the picture's width.
        public var frequency: Double
        public var phase: Double
        public var color: UInt32
        public var alpha: Double

        public init(
            level: Double, amplitude: Double, frequency: Double, phase: Double, _ color: UInt32, alpha: Double = 1
        ) {
            self.level = level
            self.amplitude = amplitude
            self.frequency = frequency
            self.phase = phase
            self.color = color
            self.alpha = alpha
        }
    }

    /// Everything one picture is made of.
    public struct Recipe: Sendable {
        public var topLeft: UInt32
        public var bottomRight: UInt32
        public var glows: [Glow]
        public var waves: [Wave]
        public var ribbons: [Ribbon]
        public var vignette: UInt32
        public var vignetteAlpha: Double

        public init(
            topLeft: UInt32, bottomRight: UInt32, glows: [Glow], waves: [Wave] = [], ribbons: [Ribbon] = [],
            vignette: UInt32 = 0, vignetteAlpha: Double = 0
        ) {
            self.topLeft = topLeft
            self.bottomRight = bottomRight
            self.glows = glows
            self.waves = waves
            self.ribbons = ribbons
            self.vignette = vignette
            self.vignetteAlpha = vignetteAlpha
        }
    }

    // MARK: Wallpapers

    /// Deep indigo with violet light from the top left and magenta from the bottom right, in the
    /// colours of the app icon.
    public static let darkWallpaper = Recipe(
        topLeft: 0x1B0C4C, bottomRight: 0x0D052C,
        glows: [
            Glow(0.50, 0.52, radius: 0.55, 0x2C0F88, alpha: 0.55, stretchX: 1.25, stretchY: 0.85),
            Glow(0.08, 0.06, radius: 0.52, 0x8743FA, alpha: 0.85, stretchX: 1.3, stretchY: 0.95),
            Glow(0.94, 0.97, radius: 0.55, 0xA522FC, alpha: 0.70, stretchX: 1.25, stretchY: 0.9),
            Glow(0.98, 0.08, radius: 0.30, 0xD782FB, alpha: 0.42),
            Glow(0.00, 0.95, radius: 0.34, 0x9E9FF4, alpha: 0.30),
            Glow(0.80, 0.42, radius: 0.30, 0x966DF8, alpha: 0.20),
        ],
        ribbons: [
            Ribbon(
                [
                    CGPoint(x: -0.15, y: 0.80), CGPoint(x: 0.25, y: 0.40), CGPoint(x: 0.62, y: 1.00),
                    CGPoint(x: 1.15, y: 0.50),
                ], width: 0.16, 0xB57CFF, alpha: 0.022, additive: true),
            Ribbon(
                [
                    CGPoint(x: -0.15, y: 0.22), CGPoint(x: 0.32, y: 0.52), CGPoint(x: 0.70, y: 0.02),
                    CGPoint(x: 1.15, y: 0.30),
                ], width: 0.12, 0xD782FB, alpha: 0.016, additive: true),
        ],
        vignette: 0x07021A, vignetteAlpha: 0.45)

    /// Pale lavender and white, with periwinkle and pink at the corners.
    public static let lightWallpaper = Recipe(
        topLeft: 0xFDFBFF, bottomRight: 0xEBDFFC,
        glows: [
            Glow(0.06, 0.04, radius: 0.55, 0xD8BFFA, alpha: 1.0, stretchX: 1.3, stretchY: 0.95),
            Glow(0.95, 0.98, radius: 0.58, 0x9E9FF4, alpha: 0.62, stretchX: 1.25, stretchY: 0.9),
            Glow(0.99, 0.04, radius: 0.32, 0xD782FB, alpha: 0.42),
            Glow(0.00, 0.98, radius: 0.38, 0x966DF8, alpha: 0.34),
            Glow(0.74, 0.38, radius: 0.34, 0xF4EAFF, alpha: 0.55),
            Glow(0.46, 0.56, radius: 0.40, 0xFFFFFF, alpha: 0.50),
        ],
        ribbons: [
            Ribbon(
                [
                    CGPoint(x: -0.15, y: 0.80), CGPoint(x: 0.25, y: 0.40), CGPoint(x: 0.62, y: 1.00),
                    CGPoint(x: 1.15, y: 0.50),
                ], width: 0.16, 0xFFFFFF, alpha: 0.06, additive: false),
            Ribbon(
                [
                    CGPoint(x: -0.15, y: 0.22), CGPoint(x: 0.32, y: 0.52), CGPoint(x: 0.70, y: 0.02),
                    CGPoint(x: 1.15, y: 0.30),
                ], width: 0.12, 0xE4D2FB, alpha: 0.05, additive: false),
        ],
        vignette: 0xC9B2F2, vignetteAlpha: 0.26)

    // MARK: Rendering

    /// Renders `recipe` at `pixels`, in sRGB.
    ///
    /// It draws in 32-bit float and rounds to 8 bits itself. Core Graphics dithers gradients drawn
    /// into an 8-bit context, and that noise would make every capture several times larger as PNG.
    public static func render(_ recipe: Recipe, pixels: CGSize) -> CGImage? {
        let width = Int(pixels.width.rounded())
        let height = Int(pixels.height.rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(recipe, in: context, size: CGSize(width: width, height: height), space: space)
        return roundedTo8Bits(context, width: width, height: height, space: space)
    }

    private static func draw(_ recipe: Recipe, in context: CGContext, size: CGSize, space: CGColorSpace) {
        let long = max(size.width, size.height)

        // Base: a diagonal gradient from the top-left colour to the bottom-right one.
        if let base = CGGradient(
            colorsSpace: space, colors: [color(recipe.topLeft), color(recipe.bottomRight)] as CFArray,
            locations: [0, 1])
        {
            context.drawLinearGradient(
                base, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for glow in recipe.glows { draw(glow, in: context, size: size, space: space) }
        for wave in recipe.waves { draw(wave, in: context, size: size, space: space) }
        for ribbon in recipe.ribbons {
            context.saveGState()
            context.setBlendMode(ribbon.additive ? .plusLighter : .normal)
            let samples = 90
            for index in 0...samples {
                let point = bezier(ribbon.points, Double(index) / Double(samples))
                draw(
                    Glow(point.x, point.y, radius: ribbon.width, ribbon.color, alpha: ribbon.alpha), in: context,
                    size: size, space: space)
            }
            context.restoreGState()
        }
        if recipe.vignetteAlpha > 0 {
            let tone = color(recipe.vignette)
            let stops: [CGFloat] = [0, 0.55, 0.8, 1]
            let alphas: [CGFloat] = [0, 0, 0.55, 1].map { $0 * recipe.vignetteAlpha }
            let colors = alphas.map { tone.copy(alpha: $0) ?? tone }
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: size.width / long, y: size.height / long)
                context.drawRadialGradient(
                    gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: long * 0.72,
                    options: [.drawsAfterEndLocation])
                context.restoreGState()
            }
        }
    }

    /// The float context's pixels rounded to an opaque 8-bit image, with no dithering.
    private static func roundedTo8Bits(_ context: CGContext, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let data = context.data else { return nil }
        let count = width * height * 4
        let floats = data.bindMemory(to: Float.self, capacity: count)
        var bytes = [UInt8](repeating: 255, count: count)
        for index in 0..<count where index % 4 != 3 {
            let value = min(max(floats[index], 0), 1)
            bytes[index] = UInt8((value * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func draw(_ wave: Wave, in context: CGContext, size: CGSize, space: CGColorSpace) {
        let path = CGMutablePath()
        let steps = 120
        func edge(_ fraction: Double) -> CGPoint {
            let swing =
                sin(2 * .pi * (wave.frequency * fraction + wave.phase))
                + 0.35 * sin(2 * .pi * (wave.frequency * 2.3 * fraction + wave.phase * 1.7))
            let y = wave.level + wave.amplitude * swing / 1.35
            return CGPoint(x: fraction * size.width, y: (1 - y) * size.height)
        }
        path.move(to: CGPoint(x: 0, y: 0))
        for step in 0...steps { path.addLine(to: edge(Double(step) / Double(steps))) }
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.closeSubpath()
        let tone = color(wave.color)
        let top = (1 - wave.level + wave.amplitude) * size.height
        guard
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [tone.copy(alpha: wave.alpha) ?? tone, tone.copy(alpha: wave.alpha * 0.55) ?? tone] as CFArray,
                locations: [0, 1])
        else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: top), end: .zero,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func draw(_ glow: Glow, in context: CGContext, size: CGSize, space: CGColorSpace) {
        let long = max(size.width, size.height)
        let tone = color(glow.color)
        let steps = 24
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let falloff = exp(-3.2 * t * t) * pow(1 - t * t, 2)
            colors.append(tone.copy(alpha: glow.alpha * falloff) ?? tone)
            locations.append(CGFloat(t))
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else {
            return
        }
        context.saveGState()
        context.translateBy(x: glow.x * size.width, y: (1 - glow.y) * size.height)
        context.scaleBy(x: glow.stretchX, y: glow.stretchY)
        context.drawRadialGradient(
            gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: glow.radius * long, options: [])
        context.restoreGState()
    }

    private static func bezier(_ points: [CGPoint], _ t: Double) -> (x: Double, y: Double) {
        guard points.count == 4 else { return (Double(points.first?.x ?? 0), Double(points.first?.y ?? 0)) }
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return (
            a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x,
            a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y
        )
    }

    /// An opaque sRGB colour from a hex value.
    public static func color(_ hex: UInt32, alpha: Double = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A borderless window that shows one picture, for the backdrop behind the panel in a product
/// shot. Order it below the panel and close it right after the capture.
public final class ShowcaseBackdropWindow: NSWindow {
    private let pictureLayer = CALayer()

    public init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        level = .floating
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(pictureLayer)
        pictureLayer.frame = view.bounds
        pictureLayer.contentsGravity = .resize
        pictureLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        contentView = view
    }

    /// Shows `image`, stretched to the window.
    public func show(_ image: CGImage?) {
        pictureLayer.contentsScale = backingScaleFactor
        pictureLayer.contents = image
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}
