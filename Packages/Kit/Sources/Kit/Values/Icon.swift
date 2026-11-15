import Foundation

/// What an icon should show. Features describe icons; the host resolves them from its icon atlas or
/// loads them off the main thread, so building one costs nothing and never touches the disk.
public enum Icon: Hashable, Sendable, Codable {
    /// An SF Symbol by name, optionally tinted.
    case symbol(String, tint: KitColor? = nil)
    /// Short text drawn as the icon, usually one emoji.
    case glyph(String)
    /// An application's icon by bundle identifier.
    case app(bundleID: String)
    /// The icon Finder shows for the file or folder at this path.
    case file(path: String)
    /// The generic icon for a type: a uniform type identifier such as `public.png`, or an extension.
    case fileType(String)
    /// A local image file drawn as is, such as a PNG next to a script.
    case image(path: String)
    /// A swatch of a color.
    case color(KitColor)
    /// A website's icon. The host shows a cached favicon, or a generic globe until one is cached.
    case favicon(domain: String)
    /// An image at an `https` URL, such as a script's icon. The host downloads it off the main thread
    /// the first time a row shows it, caches it, and draws a generic image until then. That download
    /// is a request the user did not ask for, so features keep this off rows: download after a user
    /// action into the cache folder and use ``image(path:)``. See the house rules in docs/FEATURES.md.
    case remote(URL)
    /// One icon in light appearance and another in dark. Only this case is boxed, so the common cases
    /// cost no allocation.
    indirect case adaptive(light: Icon, dark: Icon)
}
