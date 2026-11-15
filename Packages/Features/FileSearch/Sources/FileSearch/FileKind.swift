import CoreBridge

/// The kinds the Search Files dropdown filters by. Folders and applications come from the index's
/// flags; the others from the name's extension, so filtering reads nothing from the disk.
nonisolated enum FileKind: String, CaseIterable, Hashable, Sendable {
    case folders
    case documents
    case images
    case audio
    case video
    case archives
    case code
    case applications

    /// The dropdown option for every kind.
    static let allID = "all"

    /// The kind of an entry, or nil when it is none of these.
    static func of(name: String, isFolder: Bool, isPackage: Bool) -> FileKind? {
        let ext = fileExtension(of: name)
        if isPackage {
            if ext == "app" { return .applications }
            return byExtension[ext]
        }
        if isFolder { return .folders }
        return byExtension[ext]
    }

    /// The kind of an index entry.
    static func of(name: String, flags: FileEntryFlags) -> FileKind? {
        of(name: name, isFolder: flags.contains(.directory), isPackage: flags.contains(.package))
    }

    /// What the index's own kind filter can do for this kind, before the extension check.
    var indexKinds: FileSearchOptions.Kinds {
        switch self {
        case .folders, .applications: .folders
        case .documents, .images, .audio, .video, .archives, .code: .all
        }
    }

    /// The lowercase extension of a name, or "" when it has none. A leading dot is not one.
    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static let byExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        let lists: [(FileKind, [String])] = [
            (
                .documents,
                [
                    "pdf", "doc", "docx", "rtf", "rtfd", "txt", "text", "md", "markdown", "pages", "numbers", "key",
                    "xls", "xlsx", "csv", "tsv", "ppt", "pptx", "odt", "ods", "odp", "epub", "tex", "log",
                ]
            ),
            (
                .images,
                [
                    "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "raw", "cr2",
                    "cr3", "nef", "arw", "dng", "psd", "ai", "sketch", "icns", "ico", "avif",
                ]
            ),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf", "mid", "midi"]),
            (.video, ["mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]),
            (.archives, ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "sit", "zst"]),
            (
                .code,
                [
                    "swift", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "js", "mjs", "ts", "tsx", "jsx", "py", "rb",
                    "go", "java", "kt", "cs", "php", "sh", "zsh", "bash", "fish", "pl", "lua", "r", "sql", "json",
                    "yaml", "yml", "toml", "xml", "html", "css", "scss", "ipynb", "vue", "svelte", "dart", "scala",
                    "ex", "exs", "hs", "ml", "clj",
                ]
            ),
        ]
        for (kind, extensions) in lists {
            for ext in extensions { table[ext] = kind }
        }
        return table
    }()
}
