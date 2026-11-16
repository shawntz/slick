import Foundation
import Kit
import KitTesting
import Testing

@testable import Quicklinks

@Suite("Import and export", .timeLimit(.minutes(1)))
@MainActor
struct ImportExportTests {
    @Test func exportWritesEveryQuicklinkToTheChosenFile() async throws {
        var file = Samples.samplesOnly
        file.quicklinks[0].isEnabled = false
        file.quicklinks[0].openWith = Samples.browserID
        let quicklinks = try await QuicklinksHarness(file: file)
        let destination = exchangeFile(quicklinks, "export/Quicklinks.json")
        quicklinks.fakes.fileDialogs.saveLocation = destination
        try await quicklinks.harness.run("export")
        #expect(quicklinks.fakes.fileDialogs.saveRequests.first?.suggestedName == Strings.exportFileName)
        #expect(quicklinks.harness.toasts.last?.title == "Exported 3 Quicklinks")

        let exported = try JSONDecoder().decode([ExchangedQuicklink].self, from: Data(contentsOf: destination))
        #expect(exported.map(\.name) == ["Sample Docs", "Sample Tracker", "Sample Search"])
        #expect(exported[0].enabled == false && exported[0].openWith == Samples.browserID)
        #expect(exported[1].enabled == nil && exported[1].keywords == ["issue"])
        #expect(exported[2].fallback == true)
        #expect(
            exported[2].link == "https://search.example.org/find?q={argument name=\"Query\"}",
            "Raycast reads the long form of {query}")
        // Raycast's shape: a list of objects with a name and a link.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]]
        #expect(raw?.allSatisfy { $0["name"] is String && $0["link"] is String } == true)
    }

    @Test func aCancelledDialogDoesNothing() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let exported = try await quicklinks.harness.run("export")
        let imported = try await quicklinks.harness.run("import")
        #expect(exported.kind == .keepOpen && imported.kind == .keepOpen)
        #expect(quicklinks.harness.toasts.isEmpty)
        #expect(quicklinks.fakes.fileDialogs.openRequests.first?.allowedTypes == ["json", "plist"])
    }

    @Test func anExportImportsIntoAnotherSetupAndSkipsDuplicates() async throws {
        let source = try await QuicklinksHarness(file: Samples.file)
        let destination = exchangeFile(source, "export.json")
        source.fakes.fileDialogs.saveLocation = destination
        try await source.harness.run("export")

        let target = try await QuicklinksHarness()
        try await importAndConfirm(target, destination)
        let names = target.feature.entries.map(\.quicklink.name)
        #expect(names.suffix(3) == ["Sample Docs", "Sample Tracker", "Sample Search"])
        #expect(names.count == DefaultSearches.all.count + 3, "the built-ins were duplicates")
        let toast = try #require(target.harness.toasts.last)
        #expect(toast.title == "Imported 3 Quicklinks")
        #expect(toast.message == "Skipped \(DefaultSearches.all.count) duplicates.")
        #expect(target.harness.page == nil, "confirming goes back")
        let imported = try #require(target.feature.entries.last?.quicklink)
        #expect(imported.id != Samples.search.id && !imported.isBuiltIn)
        #expect(!imported.isFallback, "an import never turns a fallback on")
        #expect(try await target.storedFile()?.quicklinks.count == DefaultSearches.all.count + 3)

        // Again: nothing is new, so no page shows.
        target.fakes.fileDialogs.filesToChoose = [destination]
        try await target.harness.run("import")
        #expect(target.harness.page == nil)
        #expect(target.harness.toasts.last?.title == "No New Quicklinks to Import")

        // Back into the setup it came from, where Sample Search still writes {query} short.
        source.fakes.fileDialogs.filesToChoose = [destination]
        try await source.harness.run("import")
        #expect(source.harness.page == nil)
        #expect(source.harness.toasts.last?.title == "No New Quicklinks to Import")
    }

    @Test func aRaycastListShowsWhatHappensThenImports() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "raycast.json")
        try write(
            """
            [
              {"name": "Team Wiki", "link": "https://wiki.example.com/{argument name=\\"Page\\"}", "openWith": "com.example.browser"},
              {"name": "Board", "link": "board.example.com", "openWith": "Example Browser", "iconName": "star"},
              {"name": "Find", "link": "https://find.example.com/?q={argument}"},
              {"name": "", "link": "https://empty-name.example.com"},
              {"link": "https://no-name.example.com"},
              {"name": "Broken", "link": "https://x.example.com/{argument nme=\\"a\\"}"},
              {"name": "Sample Docs", "link": "https://docs.example.com/guide"},
              42
            ]
            """, to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        try await quicklinks.harness.run("import")
        let harness = quicklinks.harness
        #expect(
            sectionTitles(harness) == [
                "add": ["Team Wiki", "Board", "Find"], "duplicate": ["Sample Docs"],
                "not-valid": ["Entry 4", "Entry 5", "Broken", "Entry 8"],
            ])
        #expect(quicklinks.feature.entries.count == 3, "nothing is saved yet")
        #expect(
            harness.rows.first { $0.title == "Board" }?.subtitle
                == "Opens in your default app. The file names “Example Browser”, which is not an app ID.")
        #expect(harness.rows.first { $0.title == "Entry 4" }?.subtitle == "It has no name.")
        #expect(harness.page?.notice?.title == "Nothing Is Saved Until You Import")
        #expect(harness.actions().map(\.title) == ["Import 3 Quicklinks"])

        try await harness.performPrimary()
        let added = quicklinks.feature.entries.suffix(3).map(\.quicklink)
        #expect(added.map(\.name) == ["Team Wiki", "Board", "Find"])
        #expect(added[0].openWith == Samples.browserID)
        #expect(added[1].openWith == nil, "an app name is not a bundle ID")
        #expect(added[1].link == "https://board.example.com")
        #expect(added[2].link == "https://find.example.com/?q={query}", "Raycast's argument is the query here")
        #expect(harness.toasts.last?.message == "Skipped 1 duplicate and 4 entries that were not valid.")
        #expect(throws: Never.self) { try harness.command(added[0].commandID) }
        // The mapped link takes the typed text as a fallback can.
        #expect(quicklinks.feature.entry(id: added[2].id)?.takesQuery == true)
    }

    @Test func raycastsUnnamedArgumentBecomesTheQuery() {
        let cases: [(String, String)] = [
            ("https://a.example.com/?q={argument}", "https://a.example.com/?q={query}"),
            ("https://a.example.com/?q={ argument }", "https://a.example.com/?q={query}"),
            (
                "https://a.example.com/?q={argument default=\"x\" | trim}",
                "https://a.example.com/?q={argument name=\"Query\" default=\"x\" | trim}"
            ),
            // Named, two unnamed, or a query already there: left as they are.
            ("https://a.example.com/{argument name=\"Page\"}", "https://a.example.com/{argument name=\"Page\"}"),
            ("https://a.example.com/{argument}/{argument}", "https://a.example.com/{argument}/{argument}"),
            ("https://a.example.com/{query}/{argument}", "https://a.example.com/{query}/{argument}"),
            ("https://a.example.com/{clipboard}", "https://a.example.com/{clipboard}"),
        ]
        for (link, expected) in cases {
            #expect(QuicklinkExchange.mappingArgument(link) == expected, "\(link)")
        }
    }

    @Test func theQueryIsWrittenInItsLongForm() {
        let cases: [(String, String)] = [
            ("https://a.example.com/?q={query}", "https://a.example.com/?q={argument name=\"Query\"}"),
            (
                "https://a.example.com/{query default=\"x\"}/{ query }",
                "https://a.example.com/{argument name=\"Query\" default=\"x\"}/{argument name=\"Query\" }"
            ),
            ("https://a.example.com/{argument name=\"Query\"}", "https://a.example.com/{argument name=\"Query\"}"),
            ("https://a.example.com/{clipboard}/{queryx}", "https://a.example.com/{clipboard}/{queryx}"),
        ]
        for (link, expected) in cases {
            #expect(QuicklinkExchange.longQuery(link) == expected, "\(link)")
            #expect(LinkTemplate(expected).takesQuery == LinkTemplate(link).takesQuery)
        }
    }

    @Test func aLinkThatIsNotForTheWebIsImportedOffAndFlagged() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "schemes.json")
        try write(
            """
            [
              {"name": "Script", "link": "file:///tmp/example.command"},
              {"name": "Code", "link": "javascript:alert(1)"},
              {"name": "Shell", "link": "ssh://host.example.com"},
              {"name": "App", "link": "x-example-app://open?item={argument}"},
              {"name": "Mail", "link": "mailto:{argument name=\\"To\\"}"},
              {"name": "Copied", "link": "{clipboard}"},
              {"name": "Plain", "link": "http://plain.example.com"}
            ]
            """, to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        try await quicklinks.harness.run("import")
        let harness = quicklinks.harness
        #expect(
            sectionTitles(harness) == [
                "add": ["Copied", "Plain"], "off": ["Script", "Code", "Shell", "App", "Mail"],
            ])
        #expect(
            harness.rows.first { $0.title == "Script" }?.subtitle
                == "Turned off, because it opens a file link, not a web page. Check it, then turn it on.")
        #expect(harness.rows.first { $0.title == "Script" }?.accessories.first == .tag("Off"))
        try await harness.performPrimary()
        #expect(harness.toasts.last?.title == "Imported 7 Quicklinks")
        #expect(harness.toasts.last?.message == "Turned 5 off, because their links are not web links.")

        let byName = Dictionary(uniqueKeysWithValues: quicklinks.feature.entries.map { ($0.quicklink.name, $0) })
        for name in ["Script", "Code", "Shell", "App", "Mail"] {
            #expect(byName[name]?.isEnabled == false, "\(name)")
        }
        #expect(byName["Copied"]?.isEnabled == true, "a value can only make a web link when it opens")
        // Nothing turned off reaches root search, so the first Return cannot open it.
        let catalog = try await harness.catalogRows().map(\.title)
        #expect(!catalog.contains("Script") && !catalog.contains("Code") && !catalog.contains("Shell"))
        #expect(catalog.contains("Plain"))
        let commands = quicklinks.feature.commands.map(\.title)
        #expect(!commands.contains("App") && !commands.contains("Mail"))
    }

    @Test func alfredWebSearchesImportFromTheirPropertyList() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let sites: [String: Any] = [
            "customSites": [
                "B0000000-0000-0000-0000-000000000001": [
                    "keyword": "ex", "text": "Search Example for '{query}'",
                    "url": "https://search.example.com/?q={query}", "enabled": true,
                ],
                "B0000000-0000-0000-0000-000000000002": [
                    "keyword": "old", "text": "Old Search {query}", "url": "https://old.example.com/{query}",
                    "enabled": false,
                ],
                "B0000000-0000-0000-0000-000000000003": [
                    "keyword": "run", "text": "Run '{query}'", "url": "x-example-app://run/{query}", "enabled": true,
                ],
                "B0000000-0000-0000-0000-000000000004": "not a dictionary",
                "B0000000-0000-0000-0000-000000000005": ["keyword": 7, "text": ["odd"], "url": 9],
            ]
        ]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: sites, format: format, options: 0)
            let entries = try QuicklinkExchange.decode(data)
            #expect(entries.map(\.name) == [nil, nil, "Old Search", "Run", "Search Example"])
            #expect(entries.last?.link == "https://search.example.com/?q={query}")
            #expect(entries.last?.keywords == ["ex"])
            #expect(entries[2].enabled == false)
        }

        let source = exchangeFile(quicklinks, "prefs.plist")
        try write("", to: source)
        try PropertyListSerialization.data(fromPropertyList: sites, format: .binary, options: 0).write(to: source)
        try await importAndConfirm(quicklinks, source)
        let byName = Dictionary(uniqueKeysWithValues: quicklinks.feature.entries.map { ($0.quicklink.name, $0) })
        #expect(byName["Search Example"]?.takesQuery == true)
        #expect(byName["Search Example"]?.quicklink.keywords == ["ex"])
        #expect(byName["Old Search"]?.isEnabled == false, "off in Alfred, off here")
        #expect(byName["Run"]?.isEnabled == false, "not a web link")
        #expect(quicklinks.harness.toasts.last?.message?.contains("2 entries that were not valid") == true)

        // A property list of another shape is refused whole.
        try PropertyListSerialization.data(fromPropertyList: ["sites": [String: String]()], format: .xml, options: 0)
            .write(to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        await #expect(throws: ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)) {
            try await quicklinks.harness.run("import")
        }
    }

    @Test func alfredTitlesLoseTheQuery() {
        #expect(AlfredWebSearches.name("Search Example for '{query}'") == "Search Example")
        #expect(AlfredWebSearches.name("Search Example for “{query}”") == "Search Example")
        #expect(AlfredWebSearches.name("{query} on Example") == "on Example")
        #expect(AlfredWebSearches.name("Example: {query}") == "Example")
        #expect(AlfredWebSearches.name("'{query}'") == nil)
    }

    @Test func theFeaturesOwnFileImportsToo() throws {
        let data = try JSONEncoder().encode(Samples.samplesOnly)
        let entries = try QuicklinkExchange.decode(data)
        #expect(entries.map(\.name) == ["Sample Docs", "Sample Tracker", "Sample Search"])
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"name": "Marked", "link": "https://m.example.com"}]"#.utf8)
        #expect(try QuicklinkExchange.decode(marked).map(\.name) == ["Marked"])
    }

    @Test func aFileThatIsNotAListOfQuicklinksIsRefused() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "notes.json")
        try write("{\"title\": \"not quicklinks\"}", to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        await #expect(throws: ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)) {
            try await quicklinks.harness.run("import")
        }
        // A folder is no file either.
        quicklinks.fakes.fileDialogs.filesToChoose = [source.deletingLastPathComponent()]
        await #expect(throws: ActionFailure(Strings.importUnreadable, message: Strings.importUnreadableMessage)) {
            try await quicklinks.harness.run("import")
        }
        #expect(quicklinks.feature.entries.count == 3)
    }

    @Test func aFileOverTenMegabytesIsRefusedUnread() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "huge.json")
        try write("", to: source)
        try Data(repeating: 0x20, count: QuicklinkExchange.maximumFileSize + 1).write(to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        await #expect(throws: ActionFailure(Strings.importTooLarge)) { try await quicklinks.harness.run("import") }
    }

    @Test func confirmingDecidesAgainstTheQuicklinksAsTheyAreThen() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        let source = exchangeFile(quicklinks, "later.json")
        try write(#"[{"name": "Later", "link": "https://later.example.com"}]"#, to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        try await quicklinks.harness.run("import")
        #expect(sectionTitles(quicklinks.harness) == ["add": ["Later"]])
        // The same quicklink arrives some other way while the page shows.
        try await quicklinks.feature.upsert(Quicklink(id: "later", name: "Later", link: "https://later.example.com"))
        try await quicklinks.harness.performPrimary()
        #expect(quicklinks.feature.entries.filter { $0.quicklink.name == "Later" }.count == 1)
        #expect(quicklinks.harness.toasts.last?.title == "No New Quicklinks to Import")
    }

    @Test func importWhileTheFileIsUnreadableRefusesBeforeTheDialog() async throws {
        let quicklinks = try await QuicklinksHarness(raw: "{ broken")
        let source = exchangeFile(quicklinks, "any.json")
        try write(#"[{"name": "One", "link": "https://one.example.com"}]"#, to: source)
        quicklinks.fakes.fileDialogs.filesToChoose = [source]
        await #expect(throws: ActionFailure(Strings.fileUnreadableTitle, message: Strings.fileUnreadableMessage)) {
            try await quicklinks.harness.run("import")
        }
        #expect(quicklinks.fakes.fileDialogs.openRequests.isEmpty)
    }

    @Test func importAndExportNeverRunFromALink() async throws {
        let quicklinks = try await QuicklinksHarness(file: Samples.samplesOnly)
        #expect(try quicklinks.harness.command("import").allowsDeepLinks == false)
        #expect(try quicklinks.harness.command("export").allowsDeepLinks == false)
        #expect(try quicklinks.harness.command("import").subtitle?.contains("unverified") == true)
        #expect(quicklinks.harness.issues.isEmpty)
    }

    @Test func planCountsWhatItSkips() {
        var idNumber = 0
        let plan = QuicklinkExchange.plan(
            [
                ExchangedQuicklink(name: "One", link: "https://one.example.com", keywords: ["One", "two words", "1"]),
                ExchangedQuicklink(name: "one", link: "https://one.example.com"),
                ExchangedQuicklink(
                    name: "Two", link: "mailto:{argument name=\"To\"}", icon: "envelope", fallback: true),
                ExchangedQuicklink(name: "Bad Icon", link: "https://icon.example.com", icon: "../x"),
                ExchangedQuicklink(name: String(repeating: "n", count: 101), link: "https://long.example.com"),
                ExchangedQuicklink(name: "No Link"),
                ExchangedQuicklink(name: "Two\nLines", link: "https://lines.example.com"),
            ],
            existing: [Samples.docs],
            makeID: {
                idNumber += 1
                return "imported-\(idNumber)"
            })
        let added = plan.quicklinks
        #expect(added.map(\.id) == ["imported-1", "imported-2", "imported-3", "imported-4"])
        #expect(added[0].keywords == ["one", "1"])
        #expect(added[1].icon == "envelope" && !added[1].isFallback && !added[1].isEnabled)
        #expect(added[2].icon == nil)
        #expect(added[3].name == "Two Lines")
        #expect(plan.added == 4 && plan.turnedOff == 1 && plan.duplicates == 1 && plan.invalid == 2)
    }

    /// Found in the second review: an imported web link that reads the clipboard or the selection
    /// was added turned on, and the file's fallback mark was kept, so a shared file could put a
    /// fallback under root search that sends what the user copied to its own host on every run.
    @Test func linksThatSendWhatTheUserCopiedOrSelectedImportTurnedOff() {
        let plan = QuicklinkExchange.plan(
            [
                ExchangedQuicklink(
                    name: "Clip", link: "https://search.example.com/?q={query}&c={clipboard}", fallback: true),
                ExchangedQuicklink(name: "Selected", link: "https://search.example.com/?s={selection}"),
                ExchangedQuicklink(
                    name: "Both", link: "https://search.example.com/?c={clipboard offset=2}&s={ selection | trim }"),
                ExchangedQuicklink(name: "Plain", link: "https://search.example.com/?q={query}", fallback: true),
            ],
            existing: [])
        let added = plan.quicklinks
        #expect(added.map(\.isEnabled) == [false, false, false, true])
        #expect(added.allSatisfy { !$0.isFallback }, "a file never turns a fallback on")
        #expect(plan.items.map { $0.outcome == .add } == [false, false, false, true])
        #expect(plan.added == 4 && plan.flagged == 3)
        #expect(
            plan.items.prefix(3).map(QuicklinkImportRows.subtitle) == [
                "Turned off, because it sends what you copied to the site it opens. Check it, then turn it on.",
                "Turned off, because it sends what you selected to the site it opens. Check it, then turn it on.",
                "Turned off, because it sends what you copied and selected to the site it opens. "
                    + "Check it, then turn it on.",
            ])
        #expect(
            Strings.importToast(plan).message
                == "Turned 3 off, because their links send what you copied or selected.")
    }

    // MARK: Helpers

    private func exchangeFile(_ quicklinks: QuicklinksHarness, _ name: String) -> URL {
        quicklinks.fakes.storage.root.appending(path: "exchange").appending(path: name)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Runs Import Quicklinks on the file and presses Return on the page it shows.
    private func importAndConfirm(_ quicklinks: QuicklinksHarness, _ file: URL) async throws {
        quicklinks.fakes.fileDialogs.filesToChoose = [file]
        try await quicklinks.harness.run("import")
        guard case .list(let list)? = quicklinks.harness.page?.page, list.source is QuicklinkImportPage else { return }
        try await quicklinks.harness.performPrimary()
    }

    private func sectionTitles(_ harness: FeatureHarness<QuicklinksFeature>) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: harness.sections.map { ($0.id, $0.rows.map(\.title)) })
    }
}
