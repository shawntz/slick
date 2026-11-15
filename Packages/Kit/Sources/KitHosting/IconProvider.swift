import CoreGraphics
import Kit

/// Icon images for drawing, looked up on the main thread and loaded off it.
///
/// Platform implements it over its icon cache and atlas. Host draws rows with it and SettingsUI
/// draws lists with it. The main thread only looks icons up: an image is ready from the atlas or
/// the cache, or it is not ready yet.
@MainActor public protocol IconProvider: AnyObject, Sendable {
    /// The image for an icon, or nil when it is not ready.
    ///
    /// A lookup that never reads the disk and never decodes, cheap enough for every visible row in
    /// a keystroke. On nil the provider starts loading the icon off the main thread and sends
    /// ``changes`` when it is ready; draw a placeholder until then. ``Icon/adaptive(light:dark:)``
    /// resolves by `isDark`.
    func image(for icon: Icon, size: IconSize, isDark: Bool) -> CGImage?

    /// Sent when icons that were not ready became ready. Look up the visible rows again.
    var changes: ChangeSignal { get }

    /// Loads icons ahead of use, off the main thread, such as the rows of the empty state at
    /// dismiss. Returns at once.
    func prepare(_ icons: [Icon], size: IconSize)
}

/// The size an icon is drawn at.
public struct IconSize: Hashable, Sendable {
    /// The side of the square in points.
    public var points: Double
    /// Pixels per point of the screen it is drawn on, such as 2 for a Retina display.
    public var scale: Double

    public init(points: Double, scale: Double) {
        self.points = points
        self.scale = scale
    }

    /// The side of the square in pixels, rounded up.
    public var pixels: Int {
        Int((points * scale).rounded(.up))
    }
}
