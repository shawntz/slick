import Foundation
import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Command, action, section, empty-state, toast and HUD titles use title case, as macOS menus do,
/// and end without a full stop. Everything else is a plain sentence that says what will happen.
nonisolated enum Strings {
    static let featureName = "File Search"
    static let summary = "Find files and folders by name, and browse folders by typing a path."

    enum Permissions {
        static let desktop = "Search the files on your Desktop, once you choose to include it."
        static let documents = "Search the files in your Documents folder, once you choose to include it."
        static let downloads = "Search the files in your Downloads folder, once you choose to include it."
        static let iCloudDrive = "Search the files in iCloud Drive, once you choose to include it."
        static let removableVolumes = "Search files on removable drives, once you choose to include them."
        static let networkVolumes = "Search files on network volumes, once you choose to include them."
        static let fullDiskAccess =
            "Search the protected folders you choose without a prompt for each, except iCloud Drive."
    }

    enum Root {
        static let section = "Files"
        /// The title of a file whose name shows nothing, such as a single space.
        static let blankName = "Untitled Item"
    }

    enum Commands {
        static let search = "Search Files"
        static let searchKeywords = ["find", "file", "folder", "documents", "finder", "browse", "path"]
        static let searchPlaceholder = "Search files by name, or type / or ~ to browse"

        static func fallback(_ text: String) -> String {
            "Search Files for \u{201C}\(text)\u{201D}"
        }

        static let rebuild = "Rebuild File Index"
        static let rebuildKeywords = ["reindex", "refresh", "files", "index", "update"]
        static let chooseFolders = "Choose Folders to Search"
        static let chooseKeywords = ["desktop", "documents", "downloads", "icloud", "volumes", "access", "files"]
        static let choosePlaceholder = "Search places"
    }

    enum Index {
        static let building = "Building the file index"
        static let notBuilt = "The file index is not built yet"
        static let failed = "The file index could not be built"
        static let rebuilding = "Rebuilding File Index"
        static let rebuilt = "File Index Rebuilt"
        static let rebuildFailed = "Could Not Rebuild File Index"
        static let rebuildFailedMessage = "The folders could not be read. Try again in a moment."

        /// The status line: how much the index holds and when it last changed.
        static func summary(count: Int, updated: Date, now: Date, locale: Locale) -> String {
            "\(items(count, locale: locale)), updated \(relative(updated, now: now, locale: locale))"
        }

        static func holds(_ count: Int, locale: Locale) -> String {
            "The index holds \(items(count, locale: locale))."
        }

        static func items(_ count: Int, locale: Locale) -> String {
            let number = count.formatted(.number.locale(locale))
            return count == 1 ? "1 item" : "\(number) items"
        }

        static func relative(_ date: Date, now: Date, locale: Locale) -> String {
            if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }
    }

    enum Actions {
        static let copyFile = "Copy File"
        static let copiedFile = "Copied File"
        static let copyName = "Copy Name"
        static let copiedName = "Copied Name"
        static let trashConfirm = "Move to Trash"

        /// Names the item, cut to a length a question can show.
        static func trashQuestion(_ name: String) -> String {
            let shown = name.count > 60 ? String(name.prefix(59)) + "…" : name
            return "Move “\(shown)” to the Trash?"
        }
    }

    enum Page {
        static let kindFilter = "Kind"
        static let recentSection = "Recently Used"
        static let chooseFolders = "Choose Folders…"

        static let buildingState = EmptyState(
            icon: .symbol("hourglass"), title: "Building the File Index",
            message: "Files appear once the first pass over your folders ends.")
        static let failedState = EmptyState(
            icon: .symbol("exclamationmark.triangle"), title: "File Index Unavailable",
            message: "The index could not be built. Run Rebuild File Index to try again.")
        static let noRecentsState = EmptyState(
            icon: .symbol("clock"), title: "No Recent Files",
            message: "Type to search files and folders by name. Start with / or ~ to browse a folder.")
        static let noMatchesState = EmptyState(
            icon: .symbol("magnifyingglass"), title: "No Matching Files",
            message: "No file or folder in the searched places has a name like that.")
        static let notIndexedState = EmptyState(
            icon: .symbol("folder.badge.questionmark"), title: "Folder Not Searched",
            message:
                "This folder is outside the searched places, or is one that only its own app or volume should read. "
                + "Add it in File Search settings to browse it here.")

        static let updatingTitle = "Updating the File Index"
        static let updatingMessage = "Results come from the earlier index until the walk of your folders ends."

        /// The notice while some of Desktop, Documents and Downloads are not searched.
        static func notSearchedTitle(_ places: [ProtectedPlace]) -> String {
            let names = list(places.map(Places.shortName))
            return places.count == 1 ? "\(names) Is Not Searched" : "\(names) Are Not Searched"
        }

        static let notSearchedMessage =
            "macOS asks before an app reads these folders, so \(Brand.name) reads one only once you choose it."

        static func unreadableTitle(_ places: [ProtectedPlace]) -> String {
            places.count == 1 ? "\(Places.name(places[0])) Could Not Be Read" : "Some Places Could Not Be Read"
        }

        static func unreadableMessage(_ places: [ProtectedPlace]) -> String {
            "macOS did not allow \(Brand.name) to read \(list(places.map(Places.name))). "
                + "Allow it in System Settings, then choose it again."
        }

        static func waitingTitle(_ places: [ProtectedPlace]) -> String {
            places.count == 1 ? Places.needsAccess(places[0]) : "Some Places Need Access"
        }

        static func waitingMessage(_ places: [ProtectedPlace]) -> String {
            "\(list(places.map(Places.name))) will be searched once you allow access in System Settings."
        }
    }

    enum Kinds {
        static let all = "All Kinds"

        static func title(_ kind: FileKind) -> String {
            switch kind {
            case .folders: "Folders"
            case .documents: "Documents"
            case .images: "Images"
            case .audio: "Audio"
            case .video: "Video"
            case .archives: "Archives"
            case .code: "Code"
            case .applications: "Applications"
            }
        }

        /// The kind of one item, for the detail pane when the system gives none.
        static func singular(_ kind: FileKind) -> String {
            switch kind {
            case .folders: "Folder"
            case .documents: "Document"
            case .images: "Image"
            case .audio: "Audio"
            case .video: "Video"
            case .archives: "Archive"
            case .code: "Source code"
            case .applications: "Application"
            }
        }
    }

    enum Detail {
        static let kind = "Kind"
        static let size = "Size"
        static let created = "Created"
        static let modified = "Modified"
        static let location = "Where"

        static func size(_ bytes: Int64, locale: Locale) -> String {
            bytes.formatted(.byteCount(style: .file).locale(locale))
        }
    }

    enum Places {
        static let foldersSection = "Folders"
        static let volumesSection = "Volumes"
        static let allTitle = "All Protected Folders"
        static let allSubtitle = "Desktop, Documents, Downloads and iCloud Drive, asking macOS once for each."
        static let searchAll = "Search All Protected Folders"
        static let searchingAll = "Searching Protected Folders"

        static let searchAllConfirmation = Confirmation(
            "Search All Protected Folders?",
            message: "macOS asks once for each of Desktop, Documents, Downloads and iCloud Drive. "
                + "You can stop searching any of them later.",
            confirmTitle: "Search All")
        static let iCloudConfirmation = Confirmation(
            "Search iCloud Drive?",
            message: "macOS asks whether \(Brand.name) can read iCloud Drive, even with Full Disk Access. Files "
                + "kept only in iCloud are listed by name and are not downloaded.",
            confirmTitle: "Search iCloud Drive")

        static func name(_ place: ProtectedPlace) -> String {
            switch place {
            case .iCloudDrive: "iCloud Drive"
            default: place.permission?.displayName ?? place.rawValue
            }
        }

        /// The name in a list of folders, without "Folder".
        static func shortName(_ place: ProtectedPlace) -> String {
            switch place {
            case .desktop: "Desktop"
            case .documents: "Documents"
            case .downloads: "Downloads"
            default: name(place)
            }
        }

        static func search(_ place: ProtectedPlace) -> String { "Search \(name(place))" }
        static func stop(_ place: ProtectedPlace) -> String { "Stop Searching \(name(place))" }
        static func searching(_ place: ProtectedPlace) -> String { "Searching \(name(place))" }
        static func stopped(_ place: ProtectedPlace) -> String { "Stopped Searching \(name(place))" }
        static func needsAccess(_ place: ProtectedPlace) -> String { "\(name(place)) Needs Access" }
        static let needsAccessMessage = "Allow it in System Settings. Searching starts once access is granted."

        static func tag(_ state: PlaceState) -> String {
            switch state {
            case .searched: "Searched"
            case .notSearched: "Not Searched"
            case .waitingForAccess: "Needs Access"
            case .accessDenied: "No Access"
            case .turnedOff: "Off"
            }
        }

        /// One sentence about where a place stands and what choosing it does.
        static func explanation(_ place: ProtectedPlace, _ state: PlaceState) -> String {
            let volumes = place == .removableVolumes || place == .networkVolumes
            switch state {
            case .searched:
                return volumes
                    ? "Searched. Volumes mounted later join at the next rebuild."
                    : "Searched. Changes appear as they happen."
            case .notSearched:
                if place == .iCloudDrive { return "Not searched. macOS asks once before \(Brand.name) reads it." }
                return volumes
                    ? "Not searched. macOS asks once before \(Brand.name) reads them."
                    : "Not searched. macOS asks once before \(Brand.name) reads it."
            case .waitingForAccess:
                return "Waiting for access. Allow it in System Settings and searching starts."
            case .accessDenied:
                return "Could not be read. Allow access in System Settings, then search it again."
            case .turnedOff:
                return "Not searched, as you chose."
            }
        }
    }

    enum Status {
        static let failed = "File Index Unavailable"
        static let failedMessage = "The index could not be built. Run Rebuild File Index to try again."
        static let building = "Building the File Index"
        static let buildingMessage = "Search results appear once the first pass over your folders ends."
        static let damaged = "File Index Rebuilt"
        static let damagedMessage = "The saved index could not be read, so it was built again from your folders."
        static let notFollowing = "Not Following File Changes"
        static let notFollowingMessage =
            "macOS stopped reporting changes to your files, so new and moved files may be missing. "
            + "Run Rebuild File Index to read your folders again and follow changes once more."

        static func blockedTitle(_ places: [ProtectedPlace]) -> String {
            places.count == 1 ? "\(Places.name(places[0])) Is Not Searched" : "Some Places Are Not Searched"
        }

        /// Places that wait for a missing permission start by themselves once it is granted; places
        /// whose read failed wait for the user to choose them again.
        static func blockedMessage(waiting: [ProtectedPlace], refused: [ProtectedPlace]) -> String {
            var sentences: [String] = []
            if !waiting.isEmpty {
                sentences.append(
                    "\(Page.list(waiting.map(Places.name))) will be searched once you grant access.")
            }
            if !refused.isEmpty {
                sentences.append(
                    "macOS did not allow \(Brand.name) to read \(Page.list(refused.map(Places.name))). "
                        + "Allow it in System Settings, then choose it again.")
            }
            return sentences.joined(separator: " ")
        }
    }

    enum Settings {
        static let rootSection = "Root Search"
        static let showsInRoot = "Show files in root search"
        static let showsInRootInfo =
            "Files appear in their own section once you type two characters. Type / or ~ to browse a folder, "
            + "and press Tab on a folder to list what it holds."

        static let placesSection = "Protected Places"
        static let placesFooter =
            "macOS asks before any app reads these places. \(Brand.name) reads one only after you choose it here "
            + "or on the Search Files page."
        static let searchAllInfo = "Asks macOS once for each of Desktop, Documents, Downloads and iCloud Drive."
        static let fullDiskAccessInfo =
            "With Full Disk Access, choosing a protected place needs no prompt, except iCloud Drive. Each place is "
            + "still searched only once you choose it, even when another feature asked for Full Disk Access."

        static let foldersSection = "Folders and Names"
        static let extraFolders = "Also search these folders"
        static let extraFoldersInfo =
            "Folders outside your home folder, such as a projects drive. A folder inside a protected place is "
            + "searched once that place is."
        static let excludedFolders = "Never search these folders"
        static let excludedFoldersInfo = "Nothing inside these folders is read or listed."
        static let excludedNames = "Skip these names"
        static let excludedNamesPlaceholder = "node_modules or *.log"
        static let excludedNamesInfo =
            "A plain name skips every file and folder with that name. A pattern with * or ? hides matching names "
            + "from results. Hidden files, Library, caches, package contents, and build and dependency folders "
            + "such as node_modules and .git are skipped already."
        static let includesHidden = "Include hidden files"
        static let includesHiddenInfo = "Also search names that start with a dot and files Finder hides."

        static let indexSection = "Index"
        static let rebuild = "Rebuild File Index"
        static let rebuildInfo = "Reads every searched folder again. Search keeps working meanwhile."

        static func lastUpdated(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.locale = locale
            style.timeZone = timeZone
            return "It was last updated on \(date.formatted(style))."
        }

        static func storage(_ path: String) -> String {
            "The index keeps only the names, sizes and dates of files and folders, in \(path). It never leaves "
                + "this Mac, and File Search sends nothing over the network."
        }
    }
}

nonisolated extension Strings.Page {
    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}
