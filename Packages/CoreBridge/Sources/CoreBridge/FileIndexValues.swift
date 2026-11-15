import SlickCoreC

/// What a file index holds and skips.
public struct FileIndexConfiguration: Hashable, Sendable {
    /// Absolute folders to index. Repeated roots are dropped, and so are nested ones unless
    /// `keepsRootsInSkippedFolders` keeps them.
    public var roots: [String]
    /// The home folder. With the recommended rules, its Library folder is skipped.
    public var home: String?
    /// Start from the recommended rules: dependency, build and cache folders skipped, bundles and
    /// document packages indexed as single items. The lists below add to them.
    public var useRecommendedRules: Bool
    /// Index dot names and names with the hidden flag.
    public var includeHidden: Bool
    /// Do not enter folders on another volume.
    public var oneFileSystem: Bool
    /// Names skipped wherever they appear, compared without ASCII case.
    public var skipNames: [String]
    /// Absolute paths skipped with everything below them.
    public var skipPaths: [String]
    /// Folder extensions indexed but not entered, such as every package extension Launch Services
    /// declares.
    public var leafExtensions: [String]
    /// Walker threads for a full build; 0 picks a default.
    public var walkerThreads: Int
    /// Keep a root that lies inside another root but below a folder that root skips, such as
    /// iCloud Drive's folder inside the skipped Library folder. A root below a skipped or hidden
    /// name or inside a package is kept too. Off drops every nested root.
    public var keepsRootsInSkippedFolders: Bool

    public init(
        roots: [String],
        home: String? = nil,
        useRecommendedRules: Bool = true,
        includeHidden: Bool = false,
        oneFileSystem: Bool = true,
        skipNames: [String] = [],
        skipPaths: [String] = [],
        leafExtensions: [String] = [],
        walkerThreads: Int = 0,
        keepsRootsInSkippedFolders: Bool = false
    ) {
        self.roots = roots
        self.home = home
        self.useRecommendedRules = useRecommendedRules
        self.includeHidden = includeHidden
        self.oneFileSystem = oneFileSystem
        self.skipNames = skipNames
        self.skipPaths = skipPaths
        self.leafExtensions = leafExtensions
        self.walkerThreads = walkerThreads
        self.keepsRootsInSkippedFolders = keepsRootsInSkippedFolders
    }

    /// Runs `body` with the C config and the strings buffer its spans point into.
    func withRaw(_ body: (UnsafePointer<SlickFilesConfig>, UnsafePointer<UInt8>?, Int) -> Int32) -> Int32 {
        var strings: [UInt8] = []
        func span(_ items: [String]) -> (UInt32, UInt32) {
            let start = strings.count
            for (i, item) in items.enumerated() {
                if i > 0 { strings.append(0) }
                strings.append(contentsOf: item.utf8)
            }
            return (UInt32(clamping: start), UInt32(clamping: strings.count - start))
        }
        var raw = SlickFilesConfig()
        (raw.roots_start, raw.roots_len) = span(roots)
        (raw.skip_names_start, raw.skip_names_len) = span(skipNames)
        (raw.skip_paths_start, raw.skip_paths_len) = span(skipPaths)
        (raw.leaf_extensions_start, raw.leaf_extensions_len) = span(leafExtensions)
        (raw.home_start, raw.home_len) = span(home.map { [$0] } ?? [])
        raw.threads = UInt32(clamping: walkerThreads)
        raw.flags =
            (useRecommendedRules ? UInt32(SLICK_FILES_RULES_RECOMMENDED) : 0)
            | (includeHidden ? UInt32(SLICK_FILES_RULES_INCLUDE_HIDDEN) : 0)
            | (oneFileSystem ? UInt32(SLICK_FILES_RULES_ONE_FILESYSTEM) : 0)
            | (keepsRootsInSkippedFolders ? UInt32(SLICK_FILES_RULES_KEEP_UNREACHED_ROOTS) : 0)
        return strings.withUnsafeBufferPointer { s in body(&raw, s.baseAddress, s.count) }
    }
}

/// What a walk saw.
public struct FileWalkStats: Hashable, Sendable {
    public let folders: Int
    public let entries: Int
    /// Folders that could not be listed.
    public let unreadable: Int
    public let elapsedMicroseconds: Int

    init(_ s: SlickFilesWalkStats) {
        folders = Int(clamping: s.dirs)
        entries = Int(clamping: s.entries)
        unreadable = Int(clamping: s.unreadable)
        elapsedMicroseconds = Int(clamping: s.elapsed_us)
    }
}

/// Why `FileIndex.openOrBuild` did not use the saved file.
public enum FileIndexLoadError: UInt8, Hashable, Sendable {
    /// There was no file.
    case missing = 1
    /// The file could not be read.
    case io = 2
    /// The file is damaged.
    case corrupt = 3
    /// The file has another format version.
    case version = 4
    /// The file was saved for other roots or rules.
    case mismatch = 5
}

/// What `FileIndex.openOrBuild` did.
public struct FileIndexOpenInfo: Hashable, Sendable {
    /// True when the index came from the file, false when it was built.
    public let opened: Bool
    /// Why the file was not used, when it was not.
    public let loadError: FileIndexLoadError?
    /// The FSEvents id the opened file is current to: resume the stream after it. 0 after a build.
    public let eventID: UInt64
    /// When the opened file was saved, Unix seconds. 0 after a build.
    public let savedAt: UInt64
    /// Entries in the index.
    public let entries: Int
    /// The walk, when the index was built.
    public let walk: FileWalkStats

    init(_ i: SlickFilesOpenInfo) {
        opened = i.opened == 1
        loadError = FileIndexLoadError(rawValue: i.load_error)
        eventID = i.event_id
        savedAt = i.saved_at
        entries = Int(clamping: i.entries)
        walk = FileWalkStats(i.walk)
    }
}

/// One FSEvents event: an absolute path and the event's flags, unchanged.
public struct FileEvent: Hashable, Sendable {
    public var path: String
    public var flags: UInt32

    public init(path: String, flags: UInt32) {
        self.path = path
        self.flags = flags
    }
}

/// What one batch of events did.
public struct FileUpdateStats: Hashable, Sendable {
    public let events: Int
    /// Events that needed no disk access.
    public let ignored: Int
    /// Folders listed again.
    public let rescans: Int
    public let added: Int
    public let removed: Int
    public let changed: Int
    /// True when the history was lost and every root was walked again.
    public let fullRebuild: Bool
    /// True when a new snapshot was published.
    public let published: Bool
    public let elapsedMicroseconds: Int

    init(_ s: SlickFilesUpdateStats) {
        events = Int(clamping: s.events)
        ignored = Int(clamping: s.ignored)
        rescans = Int(clamping: s.rescans)
        added = Int(s.added)
        removed = Int(s.removed)
        changed = Int(s.changed)
        fullRebuild = s.full == 1
        published = s.published == 1
        elapsedMicroseconds = Int(clamping: s.elapsed_us)
    }
}

/// An entry of one snapshot. Meaningful only with the snapshot or session it came from.
public struct FileEntryID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// What an entry is.
public struct FileEntryFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let directory = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_DIR))
    /// A folder indexed as one item, such as an app or a document package.
    public static let package = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_PACKAGE))
    public static let hidden = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_HIDDEN))
    /// A symbolic link. Never followed.
    public static let symbolicLink = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_SYMLINK))
    /// One of the index roots.
    public static let root = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_ROOT))
    /// A folder the walker could not list.
    public static let unreadable = FileEntryFlags(rawValue: UInt8(SLICK_FILES_ENTRY_UNREADABLE))
}

/// Facts about one entry.
public struct FileEntry: Hashable, Sendable {
    /// Size in bytes, exact below 2 GiB and rounded down to a MiB above. Nil for a folder.
    public let size: UInt64?
    /// The parent folder, nil for a root.
    public let parent: FileEntryID?
    /// Modification time, Unix seconds.
    public let modified: UInt32
    /// Byte length of the name, the last part of the path.
    public let nameLength: Int
    public let flags: FileEntryFlags
    /// Depth below the filesystem root.
    public let depth: Int

    init(_ e: SlickFileEntry) {
        size = e.size == UInt64.max ? nil : e.size
        parent = e.parent == UInt32.max ? nil : FileEntryID(rawValue: e.parent)
        modified = e.mtime
        nameLength = Int(e.name_len)
        flags = FileEntryFlags(rawValue: e.flags)
        depth = Int(e.depth)
    }
}

/// Counts and memory of a snapshot.
public struct FileSnapshotInfo: Hashable, Sendable {
    public let entries: Int
    /// Slots, live or dead. Entry ids are below this.
    public let slots: Int
    /// Changes every time the index publishes.
    public let generation: UInt64
    public let heapBytes: Int
    /// Bytes read through the mapped index file.
    public let mappedBytes: Int

    init(_ i: SlickFilesInfo) {
        entries = Int(clamping: i.entries)
        slots = Int(clamping: i.slots)
        generation = i.generation
        heapBytes = Int(clamping: i.heap_bytes)
        mappedBytes = Int(clamping: i.mapped_bytes)
    }
}

/// How a search hit matched.
public enum FileMatch: UInt8, Hashable, Sendable {
    /// The query matched the name.
    case name = 0
    /// Some tokens matched the name, the others folders above it.
    case ancestor = 1
    /// The last token was the extension.
    case fileExtension = 2
    /// One edit away from a word of the name.
    case typo = 3
    /// Only filters, such as an extension or a path fragment.
    case filter = 4
    /// A child of a browsed folder.
    case browse = 5
}

/// One file search result: a value copy of the C hit.
public struct FileHit: Hashable, Sendable {
    /// The entry, in the snapshot of the search.
    public let id: FileEntryID
    /// Higher is better: 10,000 times the tier, plus quality and lift.
    public let rank: Int32
    public let match: FileMatch
    /// File tier, 0 for a scattered match up to 7 for an exact name; 2 is the folder tier.
    public let tier: UInt8
    public let flags: FileEntryFlags
    /// Depth below the filesystem root.
    public let depth: UInt8

    init(_ h: SlickFileHit) {
        id = FileEntryID(rawValue: h.id)
        rank = h.rank
        match = FileMatch(rawValue: h.how) ?? .name
        tier = h.tier
        flags = FileEntryFlags(rawValue: h.flags)
        depth = h.depth
    }

    var raw: SlickFileHit {
        SlickFileHit(id: id.rawValue, rank: rank, how: match.rawValue, tier: tier, flags: flags.rawValue, depth: depth)
    }
}

/// Filters and ranking for one file search.
public struct FileSearchOptions: Hashable, Sendable {
    /// Which entries a search returns.
    public enum Kinds: UInt8, Hashable, Sendable {
        case all = 0
        case files = 1
        case folders = 2
    }

    /// Which kind ranks higher inside each tier.
    public enum Preference: UInt8, Hashable, Sendable {
        case neither = 0
        case files = 1
        case folders = 2
    }

    /// The order of a folder listing without a filter.
    public enum BrowseOrder: UInt8, Hashable, Sendable {
        case name = 0
        case modified = 1
    }

    /// Only entries strictly below this folder, an id of the snapshot the search runs on.
    public var within: FileEntryID?
    /// Current Unix time in seconds, for the recency lift. 0 turns it off.
    public var now: UInt32
    public var kinds: Kinds
    public var prefer: Preference
    public var browseOrder: BrowseOrder
    /// Return hidden entries the index holds.
    public var includeHidden: Bool
    /// Run the typo pass when nothing matches well.
    public var typos: Bool
    /// Split the search into parts that run on several cores. Off runs everything on the calling
    /// thread.
    public var parallel: Bool

    public init(
        within: FileEntryID? = nil,
        now: UInt32 = 0,
        kinds: Kinds = .all,
        prefer: Preference = .neither,
        browseOrder: BrowseOrder = .name,
        includeHidden: Bool = false,
        typos: Bool = true,
        parallel: Bool = true
    ) {
        self.within = within
        self.now = now
        self.kinds = kinds
        self.prefer = prefer
        self.browseOrder = browseOrder
        self.includeHidden = includeHidden
        self.typos = typos
        self.parallel = parallel
    }

    var raw: SlickFilesOptions {
        var flags: UInt8 = 0
        if includeHidden { flags |= UInt8(SLICK_FILES_SEARCH_HIDDEN) }
        if !typos { flags |= UInt8(SLICK_FILES_SEARCH_NO_TYPO) }
        if !parallel { flags |= UInt8(SLICK_FILES_SEARCH_SERIAL) }
        return SlickFilesOptions(
            within: within?.rawValue ?? UInt32.max, now: now, kinds: kinds.rawValue, prefer: prefer.rawValue,
            browse_sort: browseOrder.rawValue, flags: flags, reserved: 0)
    }
}

/// What the last search did.
public struct FileSearchStats: Hashable, Sendable {
    /// Entries the main pass looked at.
    public let scanned: Int
    /// The prefix pass filled the hits.
    public let prefixOnly: Bool
    /// The search narrowed the previous one.
    public let narrowed: Bool
    public let typoPassRan: Bool
    /// A folder query named a folder the index does not hold.
    public let notIndexed: Bool

    init(_ s: SlickFilesSearchStats) {
        scanned = Int(clamping: s.scanned)
        prefixOnly = s.prefix_only == 1
        narrowed = s.narrowed == 1
        typoPassRan = s.typo_ran == 1
        notIndexed = s.not_indexed == 1
    }
}
