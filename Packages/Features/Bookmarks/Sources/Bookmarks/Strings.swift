import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Command, action, section, empty-state, notice, toast and HUD titles use title case, as macOS
/// menus do, and end without a full stop. Everything else is a plain sentence.
nonisolated enum Strings {
    static let featureName = "Browser Bookmarks"
    static let summary = "Search the bookmarks of the browsers you choose, and open them in any browser."
    static let fullDiskAccessReason =
        "Read Safari’s bookmarks and Reading List, which macOS keeps behind Full Disk Access."

    static func browserName(_ browser: Browser) -> String {
        switch browser {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        }
    }

    /// A profile's name from its folder: "Profile 2" as it is, Firefox's "x1y2z3.work" as "work",
    /// and the browser's name for a browser with one profile in its own folder.
    static func profileName(folder: String, browser: Browser) -> String {
        guard !folder.isEmpty else { return browserName(browser) }
        if browser.format == .firefoxPlaces, let dot = folder.firstIndex(of: "."),
            folder.index(after: dot) < folder.endIndex
        {
            return String(folder[folder.index(after: dot)...])
        }
        return folder
    }

    /// The tag a row shows for a link that is not an ordinary web link.
    static func kindTag(_ kind: LinkKind, link: String) -> String? {
        switch kind {
        case .web: nil
        case .file: "File"
        case .app: "App Link"
        case .script: LinkKind.scheme(of: link) == "javascript" ? "Bookmarklet" : "Script"
        case .browserPage: "Browser Page"
        case .invalid: "Not a Link"
        }
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// A count with a comma between thousands, as the rest of the text is English.
    static func grouped(_ number: Int) -> String {
        let digits = String(number)
        var result = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }

    // MARK: - Folders

    enum Folders {
        static let separator = " \u{203A} "
        static let more = "\u{2026}"
        /// The subtitle of a bookmark that sits in no folder.
        static let topLevel = "Bookmarks"

        static func chromiumRoot(_ key: String) -> String {
            switch key {
            case "bookmark_bar": "Bookmarks Bar"
            case "other": "Other Bookmarks"
            case "synced": "Mobile Bookmarks"
            default: key
            }
        }

        static func safariRoot(_ title: String) -> String {
            switch title {
            case "BookmarksBar": "Favorites"
            case "BookmarksMenu": "Bookmarks Menu"
            case SafariBookmarks.readingListTitle: "Reading List"
            default: title
            }
        }

        static func firefoxRoot(guid: String?, title: String?) -> String? {
            switch guid {
            case "menu________": "Bookmarks Menu"
            case "toolbar_____": "Bookmarks Toolbar"
            case "unfiled_____": "Other Bookmarks"
            case "mobile______": "Mobile Bookmarks"
            default: title
            }
        }
    }

    // MARK: - Problems

    enum Problems {
        static let damaged = "The file is damaged, or in a format this version cannot read."
        static let accessDenied = "macOS refused access to the file."
        static let tooLarge = "The file is too large to be a bookmarks file."
        static let unreadable = "The file could not be read."
    }

    // MARK: - Commands

    enum Commands {
        static let search = "Search Bookmarks"
        static let searchKeywords = [
            "bm", "browser", "favorites", "reading list", "safari", "chrome", "firefox", "brave", "edge", "vivaldi",
            "opera", "chromium",
        ]
        static let queryPlaceholder = "Title or link"
        static let fallback: @Sendable (String) -> String = { "Search Bookmarks for \u{201C}\($0)\u{201D}" }
        static let chooseBrowsers = "Choose Bookmark Browsers"
        static let chooseBrowsersButton = "Choose Browsers"
        static let chooseKeywords = ["bookmarks", "browsers", "safari", "chrome", "firefox", "sources"]
    }

    // MARK: - The list

    enum List {
        static let placeholder = "Search bookmarks by title or link"
        static let section = "Bookmarks"
        static let filterTitle = "Browser"
        static let allBrowsers = "All Bookmarks"
        static let allProfiles = "All Profiles"
        static let readingList = "Reading List"
        static let noBrowsersTitle = "No Browsers Chosen"
        static let noBrowsersMessage = "Choose the browsers whose bookmarks you want to search."
        static let emptyTitle = "No Bookmarks"
        static let emptyMessage = "The browsers you chose have no bookmarks yet."
    }

    enum Detail {
        static let title = "Title"
        static let link = "Link"
        static let folder = "Folder"
        static let browser = "Browser"
        static let profile = "Profile"
        static let added = "Added"
        static let kind = "Type"
    }

    // MARK: - Notices

    enum Notices {
        static let chooseTitle = "Choose Browsers to Search"

        static func chooseMessage(found: [Browser]) -> String {
            guard !found.isEmpty else {
                return "No supported browser is installed. Bookmarks can come from "
                    + list(Browser.allCases.map(browserName)) + "."
            }
            return "Found " + list(found.map(browserName)) + " on this Mac. Nothing is read until you choose."
        }

        static let safariAccessTitle = "Safari Needs Full Disk Access"
        static let safariAccessMessage =
            "Grant Full Disk Access in System Settings to search Safari’s bookmarks and Reading List."
        static let grantAccess = "Grant Full Disk Access"
        static let problemsTitle = "Some Bookmarks Could Not Be Read"

        /// One sentence per problem, at most three, then how many more.
        static func problemsMessage(_ problems: [SourceProblem]) -> String {
            var sentences = problems.prefix(3).map { problem in
                let source =
                    problem.showsProfile
                    ? browserName(problem.browser) + ", " + problem.profileName : browserName(problem.browser)
                return "Could not read " + source + ". " + problem.error.message
            }
            if problems.count > 3 { sentences.append("\(problems.count - 3) more could not be read either.") }
            return sentences.joined(separator: " ")
        }
    }

    // MARK: - Actions

    enum Actions {
        static let openInDefaultBrowser = "Open in Default Browser"
        static func openIn(_ app: String) -> String { "Open in " + app }
        static let openLink = "Open Link"
        static let openLinkQuestion = "Open This Link in Another App?"
        static func openLinkMessage(scheme: String) -> String {
            "Links that start with \u{201C}\(scheme):\u{201D} open in the app that handles them, not in a browser."
        }
        static let openFile = "Open File"
        static func openFileQuestion(name: String) -> String {
            let shown = name.count > 50 ? name.prefix(49) + "\u{2026}" : Substring(name)
            return "Open \u{201C}\(shown)\u{201D}?"
        }
        static let openFileMessage =
            "This bookmark points to a file on this Mac. If the file is an app or a script, opening it runs it."
        static let copyLink = "Copy Link"
        static let copiedLink = "Copied Link"
        static let copyMarkdown = "Copy as Markdown Link"
        static let copiedMarkdown = "Copied Markdown Link"
        static let copyTitle = "Copy Title"
        static let copiedTitle = "Copied Title"
        static let reload = "Reload Bookmarks"
        static let reloaded = "Reloaded Bookmarks"
    }

    // MARK: - Choosing browsers

    enum Choose {
        static let title = "Choose Bookmark Browsers"
        static let submit = "Save"
        static let intro =
            "Choose the browsers whose bookmarks you want to search. \(Brand.name) reads their bookmark files on this Mac and sends nothing anywhere."
        static func label(_ browser: Browser) -> String {
            browser == .safari ? "Search bookmarks and the Reading List" : "Search bookmarks"
        }
        static let safariInfo =
            "Safari keeps its bookmarks behind Full Disk Access. Search Bookmarks offers to open System Settings for it."
        static let rootSearchTitle = "Root Search"
        static let rootSearchLabel = "Show bookmarks in root search"
    }

    // MARK: - Settings

    enum Settings {
        static let browsersSection = "Browsers"
        static let browsersFooter =
            "Every browser is off until you switch it on. Each profile shows by the name of its folder."

        static func browserInfo(_ browser: Browser, installed: Bool) -> String {
            let reads: String =
                switch browser.format {
                case .safariPropertyList:
                    "Reads Bookmarks.plist, Reading List included. Safari keeps it behind Full Disk Access."
                case .chromiumJSON:
                    "Reads the Bookmarks file of every \(browserName(browser)) profile."
                case .firefoxPlaces:
                    "Reads places.sqlite of every Firefox profile through a private copy, so a running Firefox is not disturbed."
                }
            return installed ? reads : reads + " Not installed on this Mac."
        }

        static let accessInfo = "Without it Safari is skipped, and nothing asks for it."
        static let readingList = "Include Safari’s Reading List"
        static let readingListInfo = "Reading List items show with Safari’s bookmarks and have their own filter."
        static let resultsSection = "Results"
        static let rootSearch = "Show bookmarks in root search"

        static func rootSearchInfo(limit: Int) -> String {
            "Up to \(grouped(limit)) bookmarks join root search: those on the bookmarks bar first, then the newest. Search Bookmarks always shows them all."
        }

        static let opensIn = "Open bookmarks in"
        static let opensInInfo = "Return opens a bookmark here. Command-Return opens it in the other place."

        static func openTarget(_ target: OpenTarget) -> String {
            switch target {
            case .defaultBrowser: "Default browser"
            case .sourceBrowser: "The browser it came from"
            }
        }

        static let privacySection = "Privacy"
        static let readsNote =
            "\(Brand.name) reads only the bookmark files of the browsers you switch on, and no history, passwords or cookies. Firefox keeps its bookmarks in the same file as its history, so \(Brand.name) copies that file for a moment and reads only the bookmarks from the copy."

        static func storesNote(cache: String) -> String {
            "Nothing is stored. Bookmarks stay in memory while \(Brand.name) runs. Firefox’s copy is made in \(cache) and deleted as soon as it is read."
        }

        static let sendsNote = "Nothing is sent, and no site icons are fetched. Each bookmark shows its browser’s icon."
    }
}
