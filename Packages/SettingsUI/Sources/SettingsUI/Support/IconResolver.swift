import CoreGraphics
import Kit
import KitHosting
import Observation

/// Icon images for settings lists, through the app's ``IconProvider``.
///
/// A lookup never touches the disk. When an icon is not ready the provider loads it off the main
/// thread and signals; the resolver bumps its revision so the lists draw again.
@Observable final class IconResolver {
    @ObservationIgnored let provider: any IconProvider
    @ObservationIgnored private let tasks = TaskBag()
    private let revision = Revision()

    init(provider: any IconProvider) {
        self.provider = provider
        tasks.follow(provider.changes, bumping: revision)
    }

    /// The image, or nil while it loads.
    func image(for icon: Icon, points: Double, scale: Double, isDark: Bool) -> CGImage? {
        revision.track()
        return provider.image(for: icon, size: IconSize(points: points, scale: scale), isDark: isDark)
    }
}
