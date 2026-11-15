import AppKit

/// Icons for the showcase catalog, drawn in code: app tiles with a gradient, a sheen and a
/// symbol, utility tiles in graphite, and document pages. They are made at twice the list's
/// 28-point icon size, so they stay sharp in 2x captures.
public enum ShowcaseIcons {
    /// Pixels per side: twice 56, the list icon at 2x.
    public static let pixels = 112

    /// An app tile: a rounded square with a vertical gradient from `top` to `bottom`, a soft
    /// sheen and a rim, and `symbol` in `glyph`.
    public static func app(_ symbol: String, top: UInt32, bottom: UInt32, glyph: UInt32 = 0xFFFFFF) -> CGImage? {
        draw { context, canvas in
            let tile = tileRect(canvas)
            let path = CGPath(
                roundedRect: tile, cornerWidth: tile.width * 0.235, cornerHeight: tile.width * 0.235, transform: nil)
            // Drop shadow under the tile.
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -2), blur: 4, color: ShowcaseArt.color(0x000000, alpha: 0.28))
            context.addPath(path)
            context.setFillColor(ShowcaseArt.color(bottom))
            context.fillPath()
            context.restoreGState()
            // Body gradient.
            context.saveGState()
            context.addPath(path)
            context.clip()
            linear(context, [ShowcaseArt.color(top), ShowcaseArt.color(bottom)], from: tile.maxY, to: tile.minY)
            // Sheen across the upper half.
            linear(
                context,
                [ShowcaseArt.color(0xFFFFFF, alpha: 0.30), ShowcaseArt.color(0xFFFFFF, alpha: 0)],
                from: tile.maxY, to: tile.midY)
            context.restoreGState()
            // Rim.
            context.saveGState()
            context.addPath(
                CGPath(
                    roundedRect: tile.insetBy(dx: 0.75, dy: 0.75), cornerWidth: tile.width * 0.225,
                    cornerHeight: tile.width * 0.225, transform: nil))
            context.setStrokeColor(ShowcaseArt.color(0xFFFFFF, alpha: 0.22))
            context.setLineWidth(1.5)
            context.strokePath()
            context.restoreGState()
            symbolImage(symbol, size: 44, color: glyph, shadow: glyph == 0xFFFFFF, in: context, center: tile.center)
        }
    }

    /// A utility tile for commands: graphite glass with a white symbol.
    public static func utility(_ symbol: String) -> CGImage? {
        app(symbol, top: 0x6B6B78, bottom: 0x2F2F38)
    }

    /// A document page with a folded corner and `symbol` in `accent`.
    public static func document(_ symbol: String, accent: UInt32) -> CGImage? {
        draw { context, canvas in
            let width = canvas * 0.70
            let height = canvas * 0.86
            let page = CGRect(x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height)
            let fold = width * 0.28
            let outline = CGMutablePath()
            outline.move(to: CGPoint(x: page.minX + 7, y: page.minY))
            outline.addLine(to: CGPoint(x: page.maxX - 7, y: page.minY))
            outline.addQuadCurve(
                to: CGPoint(x: page.maxX, y: page.minY + 7), control: CGPoint(x: page.maxX, y: page.minY))
            outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
            outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
            outline.addLine(to: CGPoint(x: page.minX + 7, y: page.maxY))
            outline.addQuadCurve(
                to: CGPoint(x: page.minX, y: page.maxY - 7), control: CGPoint(x: page.minX, y: page.maxY))
            outline.addLine(to: CGPoint(x: page.minX, y: page.minY + 7))
            outline.addQuadCurve(
                to: CGPoint(x: page.minX + 7, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
            outline.closeSubpath()
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -2), blur: 4, color: ShowcaseArt.color(0x000000, alpha: 0.25))
            context.addPath(outline)
            context.setFillColor(ShowcaseArt.color(0xFFFFFF))
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(outline)
            context.clip()
            linear(context, [ShowcaseArt.color(0xFFFFFF), ShowcaseArt.color(0xECEDF3)], from: page.maxY, to: page.minY)
            context.restoreGState()
            // The folded corner.
            let corner = CGMutablePath()
            corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
            corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 6))
            corner.addQuadCurve(
                to: CGPoint(x: page.maxX - fold + 6, y: page.maxY - fold),
                control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
            corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
            corner.closeSubpath()
            context.addPath(corner)
            context.setFillColor(ShowcaseArt.color(0xD5D7E2))
            context.fillPath()
            context.addPath(outline)
            context.setStrokeColor(ShowcaseArt.color(0xB9BCCB))
            context.setLineWidth(1.5)
            context.strokePath()
            symbolImage(
                symbol, size: 30, color: accent, shadow: false, in: context,
                center: CGPoint(x: page.midX, y: page.minY + height * 0.40))
        }
    }

    /// A folder in a light blue gradient.
    public static func folder() -> CGImage? {
        draw { context, canvas in
            let body = CGRect(x: canvas * 0.08, y: canvas * 0.16, width: canvas * 0.84, height: canvas * 0.58)
            let tab = CGRect(x: body.minX, y: body.maxY - 6, width: canvas * 0.36, height: canvas * 0.14)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -2), blur: 4, color: ShowcaseArt.color(0x000000, alpha: 0.25))
            context.addPath(CGPath(roundedRect: tab, cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.setFillColor(ShowcaseArt.color(0x4C9BF2))
            context.fillPath()
            context.addPath(CGPath(roundedRect: body, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.setFillColor(ShowcaseArt.color(0x4C9BF2))
            context.fillPath()
            context.restoreGState()
            let front = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height - 10)
            context.saveGState()
            context.addPath(CGPath(roundedRect: front, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.clip()
            linear(
                context, [ShowcaseArt.color(0x9ACDFF), ShowcaseArt.color(0x5DA8F5)], from: front.maxY, to: front.minY)
            context.restoreGState()
        }
    }

    // MARK: Drawing

    private static func draw(_ body: (CGContext, CGFloat) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        body(context, CGFloat(pixels))
        return context.makeImage()
    }

    /// The tile inside the canvas, leaving room for its shadow as macOS app icons do.
    private static func tileRect(_ canvas: CGFloat) -> CGRect {
        let side = (canvas * 0.86).rounded()
        return CGRect(
            x: ((canvas - side) / 2).rounded(), y: ((canvas - side) / 2 + 2).rounded(), width: side, height: side)
    }

    private static func linear(_ context: CGContext, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)
        else { return }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func symbolImage(
        _ name: String, size: CGFloat, color: UInt32, shadow: Bool, in context: CGContext, center: CGPoint
    ) {
        let tone = NSColor(cgColor: ShowcaseArt.color(color)) ?? .white
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tone]))
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
                configuration)
        else { return }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -1), blur: 2, color: ShowcaseArt.color(0x000000, alpha: 0.22))
        }
        let imageSize = image.size
        image.draw(
            in: CGRect(
                x: (center.x - imageSize.width / 2).rounded(), y: (center.y - imageSize.height / 2).rounded(),
                width: imageSize.width, height: imageSize.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension CGRect {
    fileprivate var center: CGPoint { CGPoint(x: midX, y: midY) }
}
