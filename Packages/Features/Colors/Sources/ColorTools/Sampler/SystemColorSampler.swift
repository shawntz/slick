import AppKit

/// The system's color sampler, `NSColorSampler`, on screen. Used only when the app runs for a
/// person; tests and scenarios never make one.
///
/// `NSColorSampler` has been in AppKit since macOS 10.15. Its header documents no permission, and
/// it is the API Apple added so apps can sample the screen without Screen Recording access: the
/// system draws the magnifier and hands back only the clicked color. It calls back on the main
/// thread, with nil when the user pressed Escape.
///
/// The color arrives in the display's color space. sRGB and Display P3 components are passed on as
/// they are, and the feature converts them with its own tested math. Any other space, such as a
/// display's own profile, is converted to extended sRGB by ColorSync through `usingColorSpace`,
/// which keeps a color outside sRGB outside it.
nonisolated final class SystemColorSampler: ColorSampler {
    init() {}

    func sample() async throws -> PickedColor? {
        try await Self.show()
    }

    @MainActor private static func show() async throws -> PickedColor? {
        let sampler = NSColorSampler()
        guard let color = await sampler.sample() else { return nil }
        guard let picked = picked(from: color) else { throw ColorSamplerError.unreadable }
        return picked
    }

    /// The components of a picked color, in sRGB, Display P3, or extended sRGB. Nil when the color
    /// cannot be read as red, green, blue and alpha.
    @MainActor private static func picked(from color: NSColor) -> PickedColor? {
        // Reading `colorSpace` raises for a color that has no components, such as a catalog color,
        // so the type is checked first.
        if color.type == .componentBased, color.colorSpace.colorSpaceModel == .rgb {
            if color.colorSpace == NSColorSpace.sRGB {
                return components(of: color, in: .sRGB)
            }
            if color.colorSpace == NSColorSpace.displayP3 {
                return components(of: color, in: .displayP3)
            }
        }
        guard let converted = color.usingColorSpace(.extendedSRGB) else { return nil }
        return components(of: converted, in: .extendedSRGB)
    }

    /// The red, green, blue and alpha of a component-based RGB color, or nil for any other color.
    /// `getComponents` writes `numberOfComponents` values, which is 4 for RGB with alpha.
    @MainActor private static func components(of color: NSColor, in space: PickedColor.Space) -> PickedColor? {
        guard color.type == .componentBased, color.colorSpace.colorSpaceModel == .rgb,
            color.numberOfComponents == 4
        else { return nil }
        var values = [CGFloat](repeating: 0, count: 4)
        values.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { color.getComponents(base) }
        }
        return PickedColor(
            space: space, red: Double(values[0]), green: Double(values[1]), blue: Double(values[2]),
            alpha: Double(values[3]))
    }
}
