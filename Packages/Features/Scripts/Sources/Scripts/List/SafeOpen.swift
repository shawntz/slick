import Foundation

/// Decides whether Return may open a file that a list script named. Script output often comes from
/// a web service, so it must not be able to start a program. Only a plain file that is not
/// executable, or a plain folder, may open. An app or any other bundle, an executable file, and a
/// file whose type runs commands or opens another target are shown in Finder instead.
///
/// Links are followed first, so a link to an app counts as the app. The checks read file metadata
/// only, and run off the main thread when the user presses Return.
nonisolated enum SafeOpen {
    /// File types that run something or open another target when opened, even without the
    /// executable bit: Terminal settings, sessions and commands, location files that open a URL,
    /// another file or a server, Java archives, the Python files Python Launcher runs, and
    /// installers. Terminal and CoreTypes declare the session and location types.
    static let refusedExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "term", "fileloc", "webloc", "inetloc", "afploc", "ftploc", "mailloc",
        "newsloc", "vncloc", "jar", "py", "pyw", "pyc", "pyo", "workflow", "pkg", "mpkg", "mobileconfig", "prefpane",
    ]

    /// True when every one of the files may open.
    @concurrent static func mayOpenAll(_ urls: [URL]) async -> Bool {
        urls.allSatisfy(mayOpen)
    }

    /// True for a plain file that is not executable or a plain folder, after links are followed.
    /// False for anything that is missing or cannot be read.
    static func mayOpen(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        for name in [url, target] where refusedExtensions.contains(name.pathExtension.lowercased()) {
            return false
        }
        var info = stat()
        guard stat(target.path(percentEncoded: false), &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0
        case S_IFDIR: return !isBundle(target)
        default: return false
        }
    }

    /// A folder that macOS may treat as an app or a plug-in: one that holds `Contents/Info.plist` or
    /// `Contents/MacOS`.
    static func isBundle(_ folder: URL) -> Bool {
        let contents = folder.appending(path: "Contents", directoryHint: .isDirectory)
        return ["Info.plist", "MacOS"].contains {
            FileManager.default.fileExists(atPath: contents.appending(path: $0).path(percentEncoded: false))
        }
    }
}
