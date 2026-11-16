import AppKit
import QuartzCore

/// A soft glow around the query field's caret, in the theme's colours from top to bottom.
///
/// The glow is one image, made when the theme or the font changes, and it follows the caret by
/// its frame alone: one frame change per keystroke, drawn by the render server. It does not blink
/// or pulse, so Reduce Motion needs nothing of it.
final class CaretGlowView: GlassDecorView {
    /// The caret's own size, which the glow surrounds.
    private(set) var caretSize = CGSize.zero
    /// How far the glow reaches past the caret on every side.
    private(set) var reach: CGFloat = 0
    private var key: [CGColor] = []

    /// Whether the theme asks for a glow at all.
    var hasGlow: Bool { !key.isEmpty }

    /// Makes the glow image for these colours around a caret as tall as `caretHeight`. Does
    /// nothing when neither changed.
    func apply(colors: [CGColor], caretHeight: CGFloat, scale: CGFloat) {
        let size = CGSize(width: 2, height: caretHeight.rounded())
        guard colors != key || size != caretSize else { return }
        key = colors
        caretSize = size
        reach = Self.outerSigma * 2.5
        layer?.contents = colors.isEmpty ? nil : Self.image(colors: colors, caret: size, reach: reach, scale: scale)
        layer?.contentsScale = scale
        if colors.isEmpty { isHidden = true }
    }

    /// Centres the glow on a caret whose middle is at `center`, in the superview's coordinates.
    func place(caretCenter center: CGPoint) {
        let width = caretSize.width + reach * 2
        let height = caretSize.height + reach * 2
        let frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.frame != frame { self.frame = frame }
        isHidden = false
        CATransaction.commit()
    }

    func hide() {
        if !isHidden { isHidden = true }
    }

    /// Spread of the bright glow close to the caret and of the faint wide one, in points. Measured
    /// on the reference: two Gaussians about the caret's centre line.
    static let innerSigma: CGFloat = 2.25
    static let outerSigma: CGFloat = 7.25
    /// Share of the strength in the inner glow.
    static let innerShare: CGFloat = 0.75

    /// The glow, drawn once: for each pixel, the colour at its height along the caret and a
    /// strength from its distance to the caret.
    static func image(colors: [CGColor], caret: CGSize, reach: CGFloat, scale: CGFloat) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let stops = colors.compactMap { color -> [CGFloat]? in
            guard let parts = color.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
                parts.count == 4
            else { return nil }
            return parts
        }
        guard !stops.isEmpty else { return nil }
        let width = Int(((caret.width + reach * 2) * scale).rounded())
        let height = Int(((caret.height + reach * 2) * scale).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let core = CGRect(x: reach, y: reach, width: caret.width, height: caret.height)
        for row in 0..<height {
            // Rows run top-down in the bitmap's memory.
            let y = (CGFloat(row) + 0.5) / scale
            let along = min(1, max(0, (y - core.minY) / core.height)) * CGFloat(stops.count - 1)
            let lower = Int(along.rounded(.down))
            let upper = min(stops.count - 1, lower + 1)
            let mix = along - CGFloat(lower)
            let color = (0..<4).map { stops[lower][$0] * (1 - mix) + stops[upper][$0] * mix }
            let dy = max(0, core.minY - y, y - core.maxY)
            for column in 0..<width {
                let x = (CGFloat(column) + 0.5) / scale
                let dx = max(0, core.minX - x, x - core.maxX)
                let distance = dx * dx + dy * dy
                let strength =
                    innerShare * exp(-distance / (2 * innerSigma * innerSigma))
                    + (1 - innerShare) * exp(-distance / (2 * outerSigma * outerSigma))
                let alpha = min(1, max(0, strength * color[3]))
                let index = (row * width + column) * 4
                pixels[index] = UInt8((color[0] * alpha * 255).rounded())
                pixels[index + 1] = UInt8((color[1] * alpha * 255).rounded())
                pixels[index + 2] = UInt8((color[2] * alpha * 255).rounded())
                pixels[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
