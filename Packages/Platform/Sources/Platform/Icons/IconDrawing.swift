import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Kit

/// The bitmap format of every icon: square, 8-bit BGRA, premultiplied, sRGB. It is what the window
/// server draws without converting, and what the atlas stores.
nonisolated enum Bitmap {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// The bytes of one square image.
    static func byteCount(pixels: Int) -> Int {
        pixels * pixels * 4
    }

    /// A square context, drawing into `data` when given, else into memory of its own.
    static func context(pixels: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(
            data: data, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: colorSpace, bitmapInfo: info)
    }

    /// A square image drawn by `draw`, or nil when it drew nothing.
    static func image(pixels: Int, draw: (CGContext) -> Bool) -> CGImage? {
        guard pixels > 0, let context = context(pixels: pixels), draw(context) else { return nil }
        return context.makeImage()
    }

    /// Runs AppKit drawing into a Core Graphics context, on any thread.
    static func withAppKit(_ context: CGContext, isDark: Bool = false, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(body)
        } else {
            body()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The largest rectangle of the image's shape that fits the square, centered.
    static func fit(width: CGFloat, height: CGFloat, in side: CGFloat, inset: CGFloat = 0) -> CGRect {
        let available = side - inset * 2
        guard width > 0, height > 0, available > 0 else { return .zero }
        let scale = min(available / width, available / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Draws the icons that need no system lookup: symbols, glyphs, color swatches and image files.
/// Every function runs off the main thread.
nonisolated enum IconDrawing {
    /// The gray of placeholder symbols, readable in both appearances.
    static let placeholderGray = KitColor.rgba(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)

    /// An SF Symbol, tinted, or in the label color of the appearance when there is no tint.
    static func symbol(_ name: String, tint: KitColor?, pixels: Int, isDark: Bool) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return Bitmap.image(pixels: pixels) { context in
            var drew = false
            Bitmap.withAppKit(context, isDark: isDark) {
                let color = Self.color(tint ?? .primary)
                let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.7, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                guard let image = base.withSymbolConfiguration(configuration) else { return }
                let rect = Bitmap.fit(
                    width: image.size.width, height: image.size.height, in: CGFloat(pixels),
                    inset: CGFloat(pixels) * 0.08)
                image.draw(in: rect)
                drew = true
            }
            return drew
        }
    }

    /// Short text, usually one emoji, centered in the square.
    static func glyph(_ text: String, pixels: Int) -> CGImage? {
        guard !text.isEmpty else { return nil }
        return Bitmap.image(pixels: pixels) { context in
            let font = CTFontCreateUIFontForLanguage(.system, CGFloat(pixels) * 0.78, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let side = CGFloat(pixels)
            let scale = min(1, side * 0.92 / max(bounds.width, bounds.height))
            context.translateBy(x: side / 2, y: side / 2)
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
            CTLineDraw(line, context)
            return true
        }
    }

    /// A rounded square filled with the color, with a faint edge so white shows on white.
    static func swatch(_ kitColor: KitColor, pixels: Int, isDark: Bool) -> CGImage? {
        Bitmap.image(pixels: pixels) { context in
            Bitmap.withAppKit(context, isDark: isDark) {
                let side = CGFloat(pixels)
                let inset = max(1, side * 0.06)
                let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.2, yRadius: side * 0.2)
                Self.color(kitColor).setFill()
                path.fill()
                NSColor(white: 0, alpha: 0.18).setStroke()
                path.lineWidth = max(1, side / 32)
                path.stroke()
            }
            return true
        }
    }

    /// An image file scaled to fit the square, or nil when it is not an image.
    static func imageFile(at url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, pixels: pixels)
    }

    /// Image data scaled to fit the square, or nil when it is not an image.
    static func imageData(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source, pixels: pixels)
    }

    private static func image(from source: CGImageSource, pixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceGetCount(source) > 0,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return Bitmap.image(pixels: pixels) { context in
            context.interpolationQuality = .high
            context.draw(
                thumbnail,
                in: Bitmap.fit(
                    width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height), in: CGFloat(pixels)))
            return true
        }
    }

    /// The AppKit color for a Kit color. Semantic colors resolve in the current drawing appearance.
    static func color(_ color: KitColor) -> NSColor {
        switch color {
        case .rgba(let red, let green, let blue, let alpha):
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .semantic(let semantic):
            switch semantic {
            case .accent: .controlAccentColor
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .mint: .systemMint
            case .teal: .systemTeal
            case .cyan: .systemCyan
            case .blue: .systemBlue
            case .indigo: .systemIndigo
            case .purple: .systemPurple
            case .pink: .systemPink
            case .brown: .systemBrown
            case .gray: .systemGray
            }
        }
    }
}
