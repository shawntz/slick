import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One palette for a whole GIF: up to 256 colours picked by median cut from pixels of every
/// frame, so colours do not shift from frame to frame.
nonisolated public struct GIFPalette: Sendable {
    /// The colours as RGB bytes, three per colour.
    public let colors: [UInt8]
    /// For each 15-bit colour, five bits per channel, the index of the nearest palette colour.
    let lookup: [UInt8]

    public var count: Int { colors.count / 3 }

    /// A palette of at most `size` colours for the pixels a sampler collected.
    public init(_ sampler: Sampler, size: Int = 256) {
        let boxes = Self.medianCut(sampler.buckets, size: max(2, min(256, size)))
        var colors: [UInt8] = []
        for box in boxes {
            var total = 0.0
            var sum = (0.0, 0.0, 0.0)
            for bucket in box {
                let weight = Double(sampler.counts[bucket])
                total += weight
                sum.0 += sampler.sums[bucket * 3]
                sum.1 += sampler.sums[bucket * 3 + 1]
                sum.2 += sampler.sums[bucket * 3 + 2]
            }
            guard total > 0 else { continue }
            colors += [sum.0, sum.1, sum.2].map { UInt8(min(255, max(0, ($0 / total).rounded()))) }
        }
        if colors.isEmpty { colors = [0, 0, 0] }
        self.colors = colors
        lookup = Self.nearestTable(colors)
    }

    /// Collects pixels from frames for a palette. Feed it every frame, or every few pixels of
    /// each, before making the palette.
    public struct Sampler: Sendable {
        var counts = [UInt32](repeating: 0, count: 32_768)
        var sums = [Double](repeating: 0, count: 32_768 * 3)

        public init() {}

        /// Every `step`-th pixel in both directions of `image`.
        public mutating func add(_ image: CGImage, step: Int = 2) {
            guard let pixels = RGBPixels(image) else { return }
            let step = max(1, step)
            for y in stride(from: 0, to: pixels.height, by: step) {
                for x in stride(from: 0, to: pixels.width, by: step) {
                    let offset = y * pixels.bytesPerRow + x * 4
                    let red = pixels.bytes[offset]
                    let green = pixels.bytes[offset + 1]
                    let blue = pixels.bytes[offset + 2]
                    let bucket = GIFPalette.bucket(red, green, blue)
                    counts[bucket] &+= 1
                    sums[bucket * 3] += Double(red)
                    sums[bucket * 3 + 1] += Double(green)
                    sums[bucket * 3 + 2] += Double(blue)
                }
            }
        }

        var buckets: [Int] { counts.indices.filter { counts[$0] > 0 } }
    }

    static func bucket(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Int {
        Int(red >> 3) << 10 | Int(green >> 3) << 5 | Int(blue >> 3)
    }

    /// Splits the used buckets into `size` boxes, each time cutting the box with the widest
    /// channel range at its median.
    private static func medianCut(_ buckets: [Int], size: Int) -> [[Int]] {
        func channel(_ bucket: Int, _ index: Int) -> Int { (bucket >> (10 - index * 5)) & 31 }
        func widest(_ box: [Int]) -> (channel: Int, range: Int) {
            var best = (channel: 0, range: -1)
            for index in 0..<3 {
                var low = 31
                var high = 0
                for bucket in box {
                    let value = channel(bucket, index)
                    low = min(low, value)
                    high = max(high, value)
                }
                if high - low > best.range { best = (index, high - low) }
            }
            return best
        }
        var boxes = [buckets]
        while boxes.count < size {
            var pick = -1
            var pickRange = 0
            var pickChannel = 0
            for (index, box) in boxes.enumerated() where box.count > 1 {
                let found = widest(box)
                if found.range > pickRange {
                    pick = index
                    pickRange = found.range
                    pickChannel = found.channel
                }
            }
            guard pick >= 0 else { break }
            let sorted = boxes[pick].sorted { channel($0, pickChannel) < channel($1, pickChannel) }
            let middle = sorted.count / 2
            boxes[pick] = Array(sorted[..<middle])
            boxes.append(Array(sorted[middle...]))
        }
        return boxes
    }

    private static func nearestTable(_ colors: [UInt8]) -> [UInt8] {
        let count = colors.count / 3
        var table = [UInt8](repeating: 0, count: 32_768)
        for bucket in 0..<32_768 {
            let red = Int((bucket >> 10) & 31) * 8 + 4
            let green = Int((bucket >> 5) & 31) * 8 + 4
            let blue = Int(bucket & 31) * 8 + 4
            var best = 0
            var bestDistance = Int.max
            for index in 0..<count {
                let dr = red - Int(colors[index * 3])
                let dg = green - Int(colors[index * 3 + 1])
                let db = blue - Int(colors[index * 3 + 2])
                // Weighted toward green, as the eye is.
                let distance = 2 * dr * dr + 4 * dg * dg + db * db
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            table[bucket] = UInt8(best)
        }
        return table
    }

    /// `image` as palette indices, one byte per pixel, with an optional 4 by 4 ordered dither of
    /// `dither` levels of eight.
    func indices(of image: CGImage, dither: Double) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let pixels = RGBPixels(image) else { return nil }
        let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 - 0.5 }
        var out = [UInt8](repeating: 0, count: pixels.width * pixels.height)
        for y in 0..<pixels.height {
            let row = y * pixels.bytesPerRow
            for x in 0..<pixels.width {
                let offset = row + x * 4
                var red = Int(pixels.bytes[offset])
                var green = Int(pixels.bytes[offset + 1])
                var blue = Int(pixels.bytes[offset + 2])
                if dither > 0 {
                    let shift = Int((bayer[(y & 3) * 4 + (x & 3)] * 8 * dither).rounded())
                    red = min(255, max(0, red + shift))
                    green = min(255, max(0, green + shift))
                    blue = min(255, max(0, blue + shift))
                }
                out[y * pixels.width + x] = lookup[GIFPalette.bucket(UInt8(red), UInt8(green), UInt8(blue))]
            }
        }
        return (out, pixels.width, pixels.height)
    }
}

/// An image's pixels as 8-bit RGBX in sRGB.
nonisolated struct RGBPixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    var bytesPerRow: Int { width * 4 }

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }
}

/// Writes an animated GIF through ImageIO with one palette for every frame. Frames identical to
/// the one before are merged into it, so a still moment costs one frame however long it lasts.
nonisolated public final class GIFWriter {
    public struct Settings: Sendable, Equatable {
        /// Colours in the palette, up to 256.
        public var colors: Int
        /// Ordered dithering from 0, none, to 1, a full step between palette colours. Dithering
        /// hides banding in the glass and costs file size.
        public var dither: Double
        /// 0 loops forever.
        public var loopCount: Int

        public init(colors: Int = 256, dither: Double = 0, loopCount: Int = 0) {
            self.colors = colors
            self.dither = dither
            self.loopCount = loopCount
        }
    }

    public enum Failure: Error { case cannotWrite }

    public let url: URL
    public let palette: GIFPalette
    public let settings: Settings
    private var pending: (indices: [UInt8], width: Int, height: Int, start: Double)?
    private var frames: [(indices: [UInt8], width: Int, height: Int, start: Double, end: Double)] = []

    /// Frames written after merging.
    public var frameCount: Int { frames.count + (pending == nil ? 0 : 1) }

    public init(url: URL, palette: GIFPalette, settings: Settings = Settings()) {
        self.url = url
        self.palette = palette
        self.settings = settings
    }

    /// Adds a frame that shows from `time` seconds until the next frame's time.
    public func add(_ image: CGImage, at time: Double) {
        guard let mapped = palette.indices(of: image, dither: settings.dither) else { return }
        if let pending {
            if pending.indices == mapped.bytes { return }
            frames.append((pending.indices, pending.width, pending.height, pending.start, time))
        }
        pending = (mapped.bytes, mapped.width, mapped.height, time)
    }

    /// Writes the file. The last frame shows until `end` seconds.
    public func finish(at end: Double) throws {
        if let pending {
            frames.append(
                (pending.indices, pending.width, pending.height, pending.start, max(end, pending.start + 0.01)))
        }
        pending = nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, frames.count, nil),
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw Failure.cannotWrite }
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: settings.loopCount]] as CFDictionary)
        var table = palette.colors
        guard let space = CGColorSpace(indexedBaseSpace: sRGB, last: palette.count - 1, colorTable: &table) else {
            throw Failure.cannotWrite
        }
        for frame in frames {
            // GIF delays are in hundredths of a second; round the edges, not the lengths, so the
            // clip keeps its timing.
            let delay = max(1, (frame.end * 100).rounded() - (frame.start * 100).rounded()) / 100
            guard let provider = CGDataProvider(data: Data(frame.indices) as CFData),
                let image = CGImage(
                    width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: frame.width, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw Failure.cannotWrite }
            CGImageDestinationAddImage(
                destination, image,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
                    ]
                ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWrite }
    }
}

/// Makes a GIF from a recorded clip in two passes: one to pick the palette from every frame, one
/// to write the frames.
nonisolated public enum GIFEncoder {
    /// What one encode produced.
    public struct Result: Sendable {
        public var frames: Int
        public var bytes: Int
        public var width: Int
        public var height: Int
    }

    public static func encode(
        clip: URL, to destination: URL, frameRate: Double, width: Int?, settings: GIFWriter.Settings = .init()
    ) async throws -> Result {
        var sampler = GIFPalette.Sampler()
        var size = (width: 0, height: 0)
        try await ClipReader.read(clip, frameRate: frameRate, width: width) { frame in
            sampler.add(frame.image, step: 3)
            size = (frame.image.width, frame.image.height)
        }
        let writer = GIFWriter(
            url: destination, palette: GIFPalette(sampler, size: settings.colors), settings: settings)
        var last = 0.0
        try await ClipReader.read(clip, frameRate: frameRate, width: width) { frame in
            writer.add(frame.image, at: frame.time)
            last = frame.time
        }
        let duration = try await ClipReader.info(of: clip).duration
        try writer.finish(at: max(duration, last + 1 / frameRate))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return Result(frames: writer.frameCount, bytes: bytes, width: size.width, height: size.height)
    }
}
