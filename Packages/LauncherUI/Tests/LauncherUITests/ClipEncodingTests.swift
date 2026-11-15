import AppKit
import CoreVideo
import Foundation
import ImageIO
import LauncherUITesting
import Testing

/// The encoders and the idle guard, without a window: clips are made from synthetic frames.
@Suite struct ClipEncodingTests {
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "clips-" + UUID().uuidString)

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A BGRA frame filled with one colour, with a white square at `x`.
    static func frame(width: Int, height: Int, blue: UInt8, squareAt x: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for column in 0..<width {
                let pixel = bytes + y * rowBytes + column * 4
                let inSquare = column >= x && column < x + 16 && y >= 8 && y < 24
                pixel[0] = inSquare ? 255 : blue
                pixel[1] = inSquare ? 255 : 40
                pixel[2] = inSquare ? 255 : 20
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// A two-second clip: the square moves for one second, then holds still.
    func makeClip(in folder: Folder) async throws -> URL {
        let url = folder.url.appending(path: "master.mp4")
        let writer = try MP4ClipWriter(url: url, width: 128, height: 64, settings: .init(bitRate: 2_000_000))
        for index in 0..<30 {
            let pixels = try #require(Self.frame(width: 128, height: 64, blue: 160, squareAt: index * 3))
            var tries = 0
            while !writer.append(pixels, at: Double(index) / 30), tries < 100 {
                tries += 1
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        try await writer.finish(at: 2)
        return url
    }

    @Test func anMP4KeepsItsLengthAndSize() async throws {
        let folder = Folder()
        let url = try await makeClip(in: folder)
        let info = try await ClipReader.info(of: url)
        #expect(abs(info.duration - 2) < 0.05)
        #expect(info.width == 128 && info.height == 64)
        var frames: [ClipFrame] = []
        try await ClipReader.read(url, frameRate: 10, width: 64) { frames.append($0) }
        #expect(frames.count == 20)
        #expect(frames.first?.image.width == 64)
        #expect(abs((frames.last?.time ?? 0) - 1.9) < 0.001)
    }

    @Test func aTranscodeDropsFramesAndShrinks() async throws {
        let folder = Folder()
        let master = try await makeClip(in: folder)
        let small = folder.url.appending(path: "small.mp4")
        let written = try await ClipReader.transcode(master, to: small, frameRate: 10, width: 64, bitRate: 300_000)
        #expect(written >= 20 && written <= 21)
        let info = try await ClipReader.info(of: small)
        #expect(info.width == 64 && info.height == 32)
        #expect(abs(info.duration - 2) < 0.15)
    }

    @Test func aGIFMergesStillFramesAndKeepsTiming() async throws {
        let folder = Folder()
        let master = try await makeClip(in: folder)
        let gif = folder.url.appending(path: "clip.gif")
        let result = try await GIFEncoder.encode(clip: master, to: gif, frameRate: 10, width: 64)
        #expect(result.bytes > 0)
        // Ten moving frames, then one still frame for the second half.
        #expect(result.frames >= 10 && result.frames <= 12)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        #expect(count == result.frames)
        var total = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gifInfo = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += (gifInfo?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        }
        #expect(abs(total - 2) < 0.05)
    }

    @Test func aPaletteKeepsFewColoursExactly() throws {
        var sampler = GIFPalette.Sampler()
        let image = try #require(Self.image(colors: [(200, 40, 90), (16, 180, 248), (248, 248, 8)]))
        sampler.add(image, step: 1)
        let palette = GIFPalette(sampler, size: 256)
        #expect(palette.count == 3)
        let colors = Set(
            stride(from: 0, to: palette.colors.count, by: 3).map {
                [palette.colors[$0], palette.colors[$0 + 1], palette.colors[$0 + 2]]
            })
        #expect(colors == [[200, 40, 90], [16, 180, 248], [248, 248, 8]])
    }

    @MainActor @Test func theWatchSeesInputAsTheIdleTimeFalling() {
        var idle = 10.0
        let watch = IdleGuard.Watch(idleSource: { idle })
        var calls = 0
        watch.onInput = { calls += 1 }
        watch.start()
        idle = 10.5
        watch.check()
        #expect(!watch.inputArrived)
        idle = 0.02
        watch.check()
        #expect(watch.inputArrived)
        idle = 0.5
        watch.stop()
        #expect(calls == 1)
    }

    @Test func theIdleTimeCanBeRead() {
        #expect((IdleGuard.idleSeconds() ?? -1) >= 0)
    }

    /// Vertical stripes of the given colours, 8 pixels each.
    static func image(colors: [(UInt8, UInt8, UInt8)]) -> CGImage? {
        let width = colors.count * 8
        let height = 8
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[x / 8]
                let offset = (y * width + x) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
