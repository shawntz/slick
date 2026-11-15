import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image files beside the database: the copied bytes as they came, and a small PNG thumbnail for
/// rows. Only the store calls these, inside its actor, so they never run on the main thread.
nonisolated enum ImageFiles {
    /// The longer side of a thumbnail, in pixels. Rows draw icons at most 64 points, so 128 covers a
    /// Retina display.
    static let thumbnailSize = 128
    /// Images with more pixels than this get no thumbnail, so a small file that unpacks into a huge
    /// picture cannot make the store decode gigabytes. The row shows the image symbol instead.
    static let thumbnailPixelLimit = 100_000_000

    /// A file extension for a uniform type identifier, such as `png` for `public.png`.
    static func fileExtension(for typeIdentifier: String?) -> String {
        typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "image"
    }

    /// The image's size in pixels, read from its header without decoding the pixels. Nil when
    /// ImageIO cannot read it.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Writes a PNG thumbnail of the image. Returns false when the bytes are not an image ImageIO
    /// can read, when the image has more than `pixelLimit` pixels, or when the file cannot be
    /// written.
    static func writeThumbnail(of data: Data, to url: URL, pixelLimit: Int = thumbnailPixelLimit) -> Bool {
        guard let size = pixelSize(of: data), size.width > 0, size.height > 0,
            size.width <= pixelLimit / size.height,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        return CGImageDestinationFinalize(destination)
    }
}
