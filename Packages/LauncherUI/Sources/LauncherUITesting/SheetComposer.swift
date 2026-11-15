import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Lays captures out in a labelled grid and writes PNG files, so a whole capture matrix can be
/// reviewed in one image.
public enum SheetComposer {
    /// One cell: an image and the caption under it.
    nonisolated public struct Cell: Sendable {
        public var image: CGImage
        public var caption: String

        public init(image: CGImage, caption: String) {
            self.image = image
            self.caption = caption
        }
    }

    /// A sheet with `title` at the top and `rows` of cells, every image scaled by `scale`.
    public static func compose(title: String, rows: [[Cell]], scale: CGFloat = 0.5) -> CGImage? {
        let padding: CGFloat = 24
        let captionHeight: CGFloat = 28
        let titleHeight: CGFloat = 44
        let cellWidth = rows.flatMap { $0 }.map { CGFloat($0.image.width) * scale }.max() ?? 0
        let cellHeight = rows.flatMap { $0 }.map { CGFloat($0.image.height) * scale }.max() ?? 0
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        let width = Int(padding + CGFloat(columns) * (cellWidth + padding))
        let height = Int(titleHeight + padding + CGFloat(rows.count) * (cellHeight + captionHeight + padding))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white,
        ]
        (title as NSString).draw(
            at: NSPoint(x: padding, y: CGFloat(height) - titleHeight + 8), withAttributes: titleAttributes)
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white,
        ]
        for (rowIndex, row) in rows.enumerated() {
            let top =
                CGFloat(height) - titleHeight - padding - CGFloat(rowIndex) * (cellHeight + captionHeight + padding)
            for (column, cell) in row.enumerated() {
                let x = padding + CGFloat(column) * (cellWidth + padding)
                let size = CGSize(width: CGFloat(cell.image.width) * scale, height: CGFloat(cell.image.height) * scale)
                context.interpolationQuality = .high
                context.draw(cell.image, in: CGRect(x: x, y: top - size.height, width: size.width, height: size.height))
                (cell.caption as NSString).draw(
                    at: NSPoint(x: x, y: top - cellHeight - captionHeight + 6), withAttributes: captionAttributes)
            }
        }
        return context.makeImage()
    }

    /// Writes `image` as a PNG file.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
