import Foundation
import Kit
import Testing

@testable import Bookmarks

@Suite("Links", .timeLimit(.minutes(1)))
struct LinkTests {
    @Test func everyLinkGetsTheRightKind() {
        let cases: [(String, LinkKind)] = [
            ("https://example.com/", .web), ("HTTP://EXAMPLE.COM", .web), ("http://example.com:8080/a?b#c", .web),
            ("file:///tmp/example/notes.txt", .file), ("javascript:alert(1)", .script), ("JavaScript:void(0)", .script),
            ("data:text/html,<p>hi</p>", .script), ("vbscript:msgbox", .script),
            ("blob:https://example.com/x", .script),
            ("chrome://flags", .browserPage), ("about:config", .browserPage), ("edge://settings", .browserPage),
            ("place:sort=8", .browserPage), ("view-source:https://example.com/", .browserPage),
            ("mailto:someone@example.com", .app), ("zoommtg://example.com/join", .app), ("x-example-app:open", .app),
            ("example.com", .invalid), ("", .invalid), ("://nothing", .invalid), ("1http://example.com", .invalid),
            ("ht tp://example.com", .invalid), ("/tmp/example", .invalid),
        ]
        for (link, kind) in cases {
            #expect(LinkKind.of(LinkKind.cleaned(link)) == kind, "\(link)")
        }
    }

    @Test func linksAreCleanedAsABrowserCleansThem() {
        #expect(LinkKind.cleaned("java\nscript:alert(1)") == "javascript:alert(1)")
        #expect(LinkKind.of(LinkKind.cleaned("java\tscr\nipt:alert(1)")) == .script)
        #expect(LinkKind.of(LinkKind.cleaned("  \u{0001}javascript:alert(1)")) == .script)
        #expect(LinkKind.cleaned("  https://example.com/ \n") == "https://example.com/")
    }

    @Test func titlesForLinksWithoutOne() {
        #expect(
            LinkText.fallbackTitle(
                for: "https://www.example.com/docs/", url: URL(string: "https://www.example.com/docs/"))
                == "example.com/docs")
        #expect(
            LinkText.fallbackTitle(for: "https://example.com/", url: URL(string: "https://example.com/"))
                == "example.com")
        #expect(LinkText.fallbackTitle(for: "javascript:void(0)", url: nil) == "javascript:void(0)")
        let long = "data:text/plain," + String(repeating: "a", count: 5_000)
        #expect(LinkText.fallbackTitle(for: long, url: nil).count == 201)
    }

    @Test func markdownLinksStayOneLink() {
        #expect(LinkText.markdown(title: "Docs", link: "https://example.com/") == "[Docs](https://example.com/)")
        #expect(
            LinkText.markdown(title: "A [b] \\ c", link: "https://example.com/a (b)")
                == "[A \\[b\\] \\\\ c](https://example.com/a%20%28b%29)")
        #expect(
            LinkText.markdown(title: "", link: "https://example.com/") == "[https://example.com/](https://example.com/)"
        )
        #expect(
            LinkText.markdown(title: "Two\nLines", link: "https://example.com/") == "[Two Lines](https://example.com/)")
    }

    @Test func oneLineTextIsShortAndClean() {
        #expect(LinkText.oneLine("  Report\n\tDraft  2 ", limit: 100) == "Report Draft 2")
        #expect(LinkText.oneLine(String(repeating: "x", count: 1_000), limit: 10) == "xxxxxxxxxx\u{2026}")
        #expect(
            LinkText.oneLine("\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{1F44B}\u{1F3FD}", limit: 100)
                == "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{1F44B}\u{1F3FD}")
        #expect(LinkText.isBlank("\u{200B}\u{200B} \n"))
        #expect(!LinkText.isBlank("\u{200B}a"))
    }
}

@Suite("Building rows", .timeLimit(.minutes(1)))
struct IndexTests {
    static func profile(_ browser: Browser, _ key: String = "") -> BrowserProfile {
        BrowserProfile(browser: browser, key: key, files: [])
    }

    @Test func rowsShowTheFolderPathAndTheBrowsersIcon() throws {
        let parsed = try ChromiumBookmarks.parse(Samples.chromeDefault)
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: parsed)], includesReadingList: true)
        #expect(snapshot.rows.map(\.title) == ["Team Wiki", "Release Checklist", "Example Domain"])
        #expect(snapshot.rows.map(\.subtitle) == ["Bookmarks bar", "Bookmarks bar \u{203A} Work", "Other bookmarks"])
        #expect(snapshot.rows.allSatisfy { $0.icon == .app(bundleID: "com.google.Chrome") })
        #expect(snapshot.rows[0].id == ItemID("bookmarks", "chrome/Default/guid-wiki"))
        #expect(snapshot.rows[0].represents == .url(URL(string: "https://wiki.example.org/")!))
        #expect(snapshot.rows[0].keywords.contains("wiki.example.org"))
        #expect(snapshot.rows.allSatisfy { $0.accessories.isEmpty }, "one profile shows no profile name")
    }

    @Test func noRowEverUsesAFaviconOrARemoteImage() throws {
        let snapshot = BookmarkIndex.build(
            [
                ProfileBookmarks(profile: Self.profile(.safari), bookmarks: try SafariBookmarks.parse(Samples.safari)),
                ProfileBookmarks(
                    profile: Self.profile(.firefox, "x.default"), bookmarks: try FirefoxPlaces.parse(Samples.firefox)),
            ], includesReadingList: true)
        for row in snapshot.rows + snapshot.catalogRows {
            guard case .app = row.icon else {
                Issue.record("row \(row.title) has icon \(String(describing: row.icon))")
                continue
            }
        }
    }

    @Test func repeatsShowOnceButTheSameLinkInAnotherFolderOrProfileShows() throws {
        let data = BookmarkFixtures.chromium(
            bar: [
                .link("Twice", "https://twice.example.com/", guid: "a"),
                .link("Twice", "https://twice.example.com/", guid: "b"),
                .folder("Elsewhere", [.link("Twice", "https://twice.example.com/", guid: "c")]),
            ])
        let parsed = try ChromiumBookmarks.parse(data)
        let snapshot = BookmarkIndex.build(
            [
                ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: parsed),
                ProfileBookmarks(profile: Self.profile(.chrome, "Profile 1"), bookmarks: parsed),
            ], includesReadingList: true)
        #expect(snapshot.rows.count == 4, "two per profile: the bar and the folder")
        #expect(
            snapshot.rows.map { $0.accessories }.allSatisfy { $0 == [.text("Default")] || $0 == [.text("Profile 1")] })
        #expect(snapshot.catalogRows.count == 1, "root search shows a link once")
    }

    @Test func keysStayUniqueWhenTheBrowsersIDsRepeatOrAreMissing() throws {
        let data = BookmarkFixtures.chromium(
            bar: [
                .link("One", "https://one.example.com/", guid: "same"),
                .link("Two", "https://two.example.com/", guid: "same"),
                .link("Three", "https://three.example.com/", guid: "same"),
            ])
        let noIDs = Samples.chromium([("Four", "https://four.example.com/")])
        var parsed = try ChromiumBookmarks.parse(data) + ChromiumBookmarks.parse(noIDs)
        parsed[3].guid = nil
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: parsed)], includesReadingList: true)
        let keys = snapshot.bookmarks.map(\.key)
        #expect(Set(keys).count == 4)
        #expect(keys[1] == "chrome/Default/same~2")
        #expect(keys[3].hasPrefix("chrome/Default/h"))
        // The key without an ID is the same on the next launch.
        let again = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: parsed)], includesReadingList: true)
        #expect(again.bookmarks.map(\.key) == keys)
    }

    @Test func untitledInvisibleAndLongTitlesBecomeReadable() throws {
        let long = String(repeating: "Very long title ", count: 20_000)
        let data = Samples.chromium([
            (nil, "https://www.untitled.example.com/path/"), ("\u{200B}\u{200B}", "https://blank.example.com/"),
            ("Line\nBreak\tTab", "https://lines.example.com/"), (long, "https://long.example.com/"),
        ])
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: try ChromiumBookmarks.parse(data))],
            includesReadingList: true)
        #expect(snapshot.rows[0].title == "untitled.example.com/path")
        #expect(snapshot.rows[1].title == "blank.example.com")
        #expect(snapshot.rows[2].title == "Line Break Tab")
        #expect(snapshot.rows[3].title.count == BookmarkIndex.titleLimit + 1)
        #expect(snapshot.rows[3].title.hasSuffix("\u{2026}"))
    }

    @Test func oddSchemesAreTaggedLeftOutOfRootSearchAndNeverRepresented() throws {
        let data = Samples.chromium([
            ("Bookmarklet", "javascript:alert(document.title)"), ("Local", "file:///tmp/example/notes.txt"),
            ("Flags", "chrome://flags"), ("Mail", "mailto:someone@example.com"), ("Data", "data:text/html,<b>x</b>"),
            ("Broken", "not a link"),
        ])
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: try ChromiumBookmarks.parse(data))],
            includesReadingList: true)
        #expect(
            snapshot.rows.map(\.accessories) == [
                [.tag("Bookmarklet")], [.tag("File")], [.tag("Browser Page")], [.tag("App Link")], [.tag("Script")],
                [.tag("Not a Link")],
            ])
        #expect(snapshot.rows.allSatisfy { $0.represents == nil })
        #expect(snapshot.catalogRows.map(\.title) == ["Local", "Mail"])
    }

    @Test func theReadingListCanBeLeftOut() throws {
        let parsed = try SafariBookmarks.parse(Samples.safari)
        let profiles = [ProfileBookmarks(profile: Self.profile(.safari), bookmarks: parsed)]
        #expect(BookmarkIndex.build(profiles, includesReadingList: true).rows.count == 3)
        let without = BookmarkIndex.build(profiles, includesReadingList: false)
        #expect(without.rows.map(\.title) == ["Project Board", "Rye Bread"])
        #expect(BookmarkFilter.dropdown(for: without.profiles).options.map(\.id) == ["all", "browser:safari"])
    }

    @Test func aLongLinkDoesNotTravelInThePayload() throws {
        let long = "https://long.example.com/?q=" + String(repeating: "a", count: 5_000)
        let data = Samples.chromium([("Long", long), ("Short", "https://short.example.com/")])
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: try ChromiumBookmarks.parse(data))],
            includesReadingList: true)
        let payloads = try snapshot.rows.map { try #require($0.payload).decode(BookmarkPayload.self) }
        #expect(payloads[0].link == nil)
        #expect(payloads[1].link == "https://short.example.com/")
        for row in snapshot.rows {
            #expect(try JSONEncoder().encode(row.payload).count < 1_024)
        }
    }

    @Test func rootSearchHoldsAtMostItsLimitBarFirstThenNewest() throws {
        var links: [FixtureNode] = []
        for index in 0..<(BookmarkIndex.catalogLimit + 500) {
            links.append(
                .link(
                    "Link \(index)", "https://site\(index).example.com/",
                    added: Date(timeIntervalSince1970: Double(index))))
        }
        let data = BookmarkFixtures.chromium(bar: [.link("On the Bar", "https://bar.example.com/")], other: links)
        let snapshot = BookmarkIndex.build(
            [ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: try ChromiumBookmarks.parse(data))],
            includesReadingList: true)
        #expect(snapshot.catalogRows.count == BookmarkIndex.catalogLimit)
        #expect(snapshot.catalogRows.first?.title == "On the Bar")
        #expect(!snapshot.catalogRows.contains { $0.title == "Link 0" }, "the oldest give way")
        #expect(snapshot.catalogRows.contains { $0.title == "Link \(BookmarkIndex.catalogLimit + 499)" })
        #expect(snapshot.catalogRows.allSatisfy { $0.keywords.count <= 1 }, "root search rows carry the host only")
    }

    @Test func theDropdownNamesBrowsersProfilesAndTheReadingList() throws {
        let chrome = try ChromiumBookmarks.parse(Samples.chromeDefault)
        let snapshot = BookmarkIndex.build(
            [
                ProfileBookmarks(profile: Self.profile(.chrome, "Default"), bookmarks: chrome),
                ProfileBookmarks(profile: Self.profile(.chrome, "Profile 1"), bookmarks: chrome),
                ProfileBookmarks(profile: Self.profile(.safari), bookmarks: try SafariBookmarks.parse(Samples.safari)),
                ProfileBookmarks(profile: Self.profile(.firefox, "abc.work"), bookmarks: []),
            ], includesReadingList: true)
        let dropdown = BookmarkFilter.dropdown(for: snapshot.profiles)
        #expect(
            dropdown.options.map(\.id) == [
                "all", "browser:safari", "reading-list", "browser:chrome", "profile:chrome/Default",
                "profile:chrome/Profile 1", "browser:firefox",
            ])
        #expect(
            dropdown.options.map(\.title) == [
                "All Bookmarks", "Safari", "Reading List", "All Profiles", "Default", "Profile 1", "Firefox",
            ])
        #expect(snapshot.rows(matching: .profile("chrome/Profile 1")).count == 3)
        #expect(snapshot.rows(matching: .readingList).map(\.title) == ["A Long Read"])
        #expect(snapshot.rows(matching: .browser(.safari)).count == 3)
        #expect(BookmarkFilter(optionID: "browser:nonsense") == .all)
        #expect(BookmarkFilter(optionID: nil) == .all)
    }

    @Test func profileNamesComeFromFolders() {
        #expect(Strings.profileName(folder: "Default", browser: .chrome) == "Default")
        #expect(Strings.profileName(folder: "Profile 3", browser: .edge) == "Profile 3")
        #expect(Strings.profileName(folder: "x1y2z3ab.default-release", browser: .firefox) == "default-release")
        #expect(Strings.profileName(folder: "nodot", browser: .firefox) == "nodot")
        #expect(Strings.profileName(folder: "trailing.", browser: .firefox) == "trailing.")
        #expect(Strings.profileName(folder: "", browser: .opera) == "Opera")
    }
}
