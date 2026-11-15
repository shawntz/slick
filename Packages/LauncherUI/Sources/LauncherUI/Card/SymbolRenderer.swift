import AppKit

/// Renders SF Symbols into tinted bitmaps for views that draw with Core Graphics.
///
/// A symbol is rendered once per name, size, colour and scale and kept by the caller's cache, so
/// redrawing a row costs an image draw, not a symbol render.
enum SymbolRenderer {
    /// A symbol's point size as a share of its box. At the full size a symbol looks heavier than
    /// the text beside it.
    private static let opticalScale: CGFloat = 0.8

    /// `name` at `pointSize`, tinted with `color`, fitted in a square of `pointSize` points at
    /// `scale` pixels per point. Nil when the system has no such symbol.
    static func image(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium, color: CGColor, scale: CGFloat
    )
        -> CGImage?
    {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize * opticalScale, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .labelColor]))
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let pixels = Int((pointSize * scale).rounded(.up))
        guard pixels > 0,
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let size = symbol.size
        let fit = min(1, pointSize / max(size.width, size.height, 1))
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        symbol.draw(
            in: CGRect(
                x: (pointSize - drawn.width) / 2, y: (pointSize - drawn.height) / 2, width: drawn.width,
                height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
