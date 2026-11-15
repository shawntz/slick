import os

/// Loggers in Slick's subsystem. Each feature gets one on its context, with its ID as the category.
///
/// These are plain `os.Logger`s, so interpolation keeps its privacy controls. Anything that comes
/// from the user's data, such as text, file names or titles, must be logged with
/// `privacy: .private`. Logs never leave the Mac.
public enum KitLog {
    /// The subsystem every Slick logger uses: the bundle identifier.
    public static let subsystem = Brand.bundleID

    /// A logger for one area of the code.
    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
