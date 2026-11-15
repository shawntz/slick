import CoreGraphics
import Kit
import KitHosting

/// Icons as solid squares, one colour per icon, for tests that draw rows without Platform.
///
/// Every icon is ready at once unless a test holds it back with ``holdBack(_:)``. A held icon reads
/// as not ready until ``deliverHeldIcons()``, which then sends ``changes``, as a late load does.
@MainActor public final class FakeIconProvider: IconProvider {
    private struct Key: Hashable {
        let icon: Icon
        let pixels: Int
    }

    public let changes = ChangeSignal()
    /// Every icon looked up, in order, after adaptive icons were resolved.
    public private(set) var lookups: [Icon] = []
    /// Every batch passed to ``prepare(_:size:)``.
    public private(set) var prepared: [[Icon]] = []

    private var held: Set<Icon> = []
    private var images: [Key: CGImage] = [:]

    public init() {}

    /// Makes the icon read as not ready until ``deliverHeldIcons()``.
    public func holdBack(_ icon: Icon) {
        held.insert(icon)
    }

    /// Makes every held icon ready and sends ``changes``. Does nothing when none is held.
    public func deliverHeldIcons() {
        guard !held.isEmpty else { return }
        held = []
        changes.send()
    }

    public func image(for icon: Icon, size: IconSize, isDark: Bool) -> CGImage? {
        let resolved = Self.resolve(icon, isDark: isDark)
        lookups.append(resolved)
        guard !held.contains(icon), !held.contains(resolved) else { return nil }
        let key = Key(icon: resolved, pixels: max(size.pixels, 1))
        if let image = images[key] { return image }
        let image = Self.solidImage(Self.color(for: resolved), pixels: key.pixels)
        images[key] = image
        return image
    }

    public func prepare(_ icons: [Icon], size: IconSize) {
        prepared.append(icons)
    }

    /// The colour the fake draws for an icon, as sRGB components from 0 to 1. Stable across runs.
    public static func color(for icon: Icon) -> (red: Double, green: Double, blue: Double) {
        let hash = FNV1a.hash64(String(describing: icon))
        return (
            Double(hash & 0xFF) / 255, Double((hash >> 8) & 0xFF) / 255, Double((hash >> 16) & 0xFF) / 255
        )
    }

    private static func resolve(_ icon: Icon, isDark: Bool) -> Icon {
        if case .adaptive(let light, let dark) = icon { return resolve(isDark ? dark : light, isDark: isDark) }
        return icon
    }

    private static func solidImage(_ color: (red: Double, green: Double, blue: Double), pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }
}
