import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a card's photo into a small PNG for the detail pane, off the main thread.
nonisolated enum PhotoThumbnail {
    /// The longest side of a thumbnail, in pixels: sharp at twice the pane's 128 points.
    static let maximumPixels = 256
    /// Photos larger than this are not decoded. A small file can unpack into a huge picture.
    static let maximumSourcePixels = 50_000_000
    /// Files larger than this are not read.
    static let maximumBytes = 20_000_000

    /// Reads the photo and scales it, both off the main thread. Nil when the card has none or it
    /// cannot be decoded.
    @concurrent static func read(_ id: String, from service: any PeopleService) async throws -> Data? {
        guard let photo = try await service.photo(of: id) else { return nil }
        try Task.checkCancellation()
        return make(from: photo)
    }

    /// A PNG at most ``maximumPixels`` on its longest side, turned upright. Nil for data that is
    /// not an image, is too large, or has no pixels.
    static func make(
        from data: Data, maximumPixels: Int = maximumPixels, maximumSourcePixels: Int = maximumSourcePixels
    ) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumSourcePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
