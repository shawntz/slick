import CoreGraphics
import Foundation

/// Measures text contrast and luminance in captured images.
nonisolated public enum ContrastMeter {
    /// An estimate of the WCAG contrast ratio of the text in `rect` (image pixels, top-left
    /// origin): the relative luminance of the 97th percentile pixel against the 3rd, so the
    /// glyph cores and the background around them. 1 means no contrast; WCAG asks 4.5 for body
    /// text and 3 for large or secondary text.
    public static func contrastRatio(_ image: CGImage, in rect: CGRect) -> Double {
        let values = linearLuminance(image, in: rect).sorted()
        guard !values.isEmpty else { return .nan }
        let low = values[Int(Double(values.count - 1) * 0.03)]
        let high = values[Int(Double(values.count - 1) * 0.97)]
        return (high + 0.05) / (low + 0.05)
    }

    /// The mean sRGB-weighted luminance of `rect`, from 0 to 1, without linearising.
    public static func meanLuminance(_ image: CGImage, in rect: CGRect) -> Double {
        guard let pixels = rgba(image, in: rect), !pixels.isEmpty else { return .nan }
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum +=
                0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return sum / Double(pixels.count / 4) / 255
    }

    /// Relative luminance per pixel, as WCAG defines it.
    static func linearLuminance(_ image: CGImage, in rect: CGRect) -> [Double] {
        guard let pixels = rgba(image, in: rect) else { return [] }
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var values: [Double] = []
        values.reserveCapacity(pixels.count / 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            values.append(
                0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2])
            )
        }
        return values
    }

    /// The pixels of `rect` as sRGB RGBA bytes.
    static func rgba(_ image: CGImage, in rect: CGRect) -> [UInt8]? {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, let crop = image.cropping(to: clipped),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = Int(clipped.width)
        let height = Int(clipped.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
