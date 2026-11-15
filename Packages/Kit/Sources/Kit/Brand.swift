/// The product's identity: the name people see, the bundle identifier, the data folder and the URL
/// scheme.
///
/// These values are written down in exactly two places: here for code and `support/brand.env` for
/// the build scripts. `scripts/check-brand.sh` fails the lint when the two disagree or when a value
/// is written out anywhere else, so renaming the product is an edit to those two files.
public enum Brand {
    /// The product name people see. It also names the app bundle and its executable.
    public static let name = "Slick"

    /// The bundle identifier. macOS keys preferences and permission grants to it, so changing it
    /// resets both.
    public static let bundleID = "com.shawnschwartz.slick"

    /// The name of the app's folder under `~/Library/Application Support`.
    public static let dataDirectoryName = "Slick"

    /// The URL scheme for deep links, without the "://".
    public static let urlScheme = "slick"
}
