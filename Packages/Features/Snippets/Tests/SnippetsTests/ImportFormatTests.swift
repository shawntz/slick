import Foundation
import Kit
import KitTesting
import Testing

@testable import Snippets

/// Reading Raycast's JSON and Alfred's collections, and mapping their placeholders. Every file is
/// built here from synthetic text.
@Suite("Import formats", .timeLimit(.minutes(1)))
struct ImportFormatTests {
    // MARK: Placeholders

    @Test func raycastPlaceholdersStayAndTheOnesKitLacksAreNoted() {
        let same = #"{clipboard} {clipboard offset=2} {date format="yyyy"} {argument name="Who"} {cursor} {uuid}"#
        #expect(PlaceholderMapping.raycast(same) == .init(text: same))
        let mapped = PlaceholderMapping.raycast("Tab: {browser-tab} {browser-tab format=\"markdown\"} {date nope=1}")
        #expect(mapped.text == "Tab: {browser-tab} {browser-tab format=\"markdown\"} {date nope=1}")
        #expect(mapped.keptAsTyped == ["{browser-tab}", "{browser-tab format=\"markdown\"}", "{date nope=1}"])
        #expect(mapped.nowFilled.isEmpty)
        // Code and JSON mean the same everywhere, so they pass unnoticed.
        let code = #"if (a) { return {"key": 1}; } {name} ${HOME}"#
        #expect(PlaceholderMapping.raycast(code) == .init(text: code))
        // A fourth argument is a mistake only in context.
        let four = "{argument name=\"a\"}{argument name=\"b\"}{argument name=\"c\"}{argument name=\"d\"}"
        #expect(PlaceholderMapping.raycast(four).keptAsTyped == ["{argument name=\"d\"}"])
    }

    @Test func alfredPlaceholdersBecomeKitsOwn() {
        let mapped = PlaceholderMapping.alfred(
            "{date} at {time}, {datetime}: {clipboard} then {clipboard:1} and {clipboard:12}. {cursor}{random:UUID}")
        #expect(
            mapped.text
                == "{date} at {time}, {datetime}: {clipboard} then {clipboard offset=1} and {clipboard offset=12}. "
                + "{cursor}{uuid}")
        #expect(mapped.keptAsTyped.isEmpty && mapped.nowFilled.isEmpty)
        #expect(PlaceholderMapping.alfred("{random:uuid}").text == "{uuid}")
    }

    @Test func alfredPlaceholdersKitLacksStayAndAreNoted() {
        let mapped = PlaceholderMapping.alfred(
            "{date:short} {random:1..6} {clipboard:x} {var:name} {snippet:sig} {selection} {uuid} {browser-tab} {name}")
        #expect(
            mapped.text
                == "{date:short} {random:1..6} {clipboard:x} {var:name} {snippet:sig} {selection} {uuid} {browser-tab} {name}"
        )
        #expect(
            mapped.keptAsTyped == ["{date:short}", "{random:1..6}", "{clipboard:x}", "{var:name}", "{snippet:sig}"])
        // Alfred left these as typed; here they fill in, so the page says so.
        #expect(mapped.nowFilled == ["{selection}", "{uuid}"])
    }

    @Test func bracesAcrossLinesOrNestedArePlainText() {
        let text = "{clip\nboard} {{clipboard}} {\"quoted}\" date}"
        let alfred = PlaceholderMapping.alfred(text)
        #expect(alfred.text == text)
        #expect(alfred.keptAsTyped.isEmpty)
        #expect(PlaceholderMapping.raycast(text) == .init(text: text))
    }

    // MARK: Keywords at scale

    /// The import checks keywords through an index, not by asking the editor's rule against every
    /// snippet. On random keywords over a small alphabet, where one often starts another, it must
    /// leave out exactly the keywords the editor's rule refuses.
    @Test func keywordChecksAgreeWithTheEditorsRule() {
        var generator = SeededGenerator(seed: 11)
        let alphabet = Array("ab;")
        for round in 0..<40 {
            let prefix = round.isMultiple(of: 2) ? "" : ";"
            let rules = SnippetValidation.Rules(prefix: prefix, trigger: .immediately)
            let existing = (0..<6).map { index in
                Fixture.snippet(
                    "Existing \(index)", "existing \(index)",
                    keyword: String(
                        (0..<Int.random(in: 1...4, using: &generator)).map { _ in
                            alphabet.randomElement(using: &generator)!
                        }), expands: Bool.random(using: &generator), id: "e\(index)")
            }
            let entries = (0..<30).map { index in
                ImportedEntry(
                    TransferEntry(
                        name: "Entry \(index)", text: "text \(index)",
                        keyword: String(
                            (0..<Int.random(in: 1...4, using: &generator)).map { _ in
                                alphabet.randomElement(using: &generator)!
                            }), expands: Bool.random(using: &generator)))
            }
            let plan = SnippetImport.plan(entries, existing: existing, at: Date(timeIntervalSince1970: 0), rules: rules)
            var saved = existing
            for item in plan.items {
                guard let snippet = item.snippet, let keyword = item.keyword else { continue }
                let editor = SnippetValidation.keywordProblem(
                    keyword, expands: snippet.expands, others: saved, rules: rules)
                let isTaken = saved.contains { $0.keyword == keyword }
                let isUntypeable = !ImportText.isTypeable(keyword)
                #expect(
                    (snippet.keyword == nil) == (editor != nil || isTaken || isUntypeable),
                    "round \(round): \(keyword) against \(saved.compactMap(\.keyword))")
                saved.append(snippet)
            }
        }
    }

    @Test func tenThousandKeywordsArePlannedWithinTheSuitesTimeLimit() {
        let existing = (0..<1_000).map {
            Fixture.snippet("Existing \($0)", "e\($0)", keyword: "ex\($0)x", id: "e\($0)")
        }
        let entries = (0..<10_000).map {
            ImportedEntry(TransferEntry(name: "Bulk \($0)", text: "bulk \($0)", keyword: "kw\($0)z"))
        }
        let rules = SnippetValidation.Rules(prefix: ";", trigger: .immediately)
        let plan = SnippetImport.plan(entries, existing: existing, at: Date(timeIntervalSince1970: 0), rules: rules)
        #expect(plan.summary.added == 10_000)
        #expect(plan.summary.withoutKeyword == 0, "no keyword starts another: each ends in a letter no other has")
    }

    // MARK: JSON

    @Test func aByteOrderMarkIsSkipped() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"name": "Marked", "text": "t"}]"#.utf8)
        let entries = try SnippetImportFile.parse(data, fileName: "marked.json")
        #expect(entries.map(\.entry.name) == ["Marked"])
    }

    // MARK: Alfred

    @Test func anAlfredCollectionImportsWithItsPrefixSuffixAndName() async throws {
        let archive = AlfredFixture.archive(
            [
                .init("Thanks", "Thanks for writing.\n{cursor}", keyword: "thx"),
                .init("Stamp", "{date} at {time}: {clipboard:1}", keyword: "stamp", dontAutoExpand: true),
                .init("New ID", "{random:UUID}", keyword: "id"),
                .init("Fancy", "{date:short} {selection}", keyword: "fancy"),
                .init("No Keyword", "plain"),
            ], prefix: ";", suffix: "!")
        let harness = try await FeatureHarness.loaded([])
        let file = harness.fakes.storage.root.appending(path: "Work Pack.alfredsnippets")
        try archive.write(to: file)
        harness.fakes.fileDialogs.filesToChoose = [file]
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.importSections == ["add": ["Thanks", "Stamp", "New ID", "Fancy", "No Keyword"]])
        #expect(harness.rows.first { $0.title == "Fancy" }?.accessories.count == 2, "its keyword and a warning")
        try await harness.performPrimary()

        let stamp = try #require(harness.snippet(named: "Stamp"))
        #expect(stamp.text == "{date} at {time}: {clipboard offset=1}")
        #expect(stamp.keyword == ";stamp!", "Alfred adds the prefix and suffix around every keyword")
        #expect(!stamp.expands)
        #expect(stamp.collection == "Work Pack")
        #expect(harness.snippet(named: "New ID")?.text == "{uuid}")
        #expect(harness.snippet(named: "Thanks")?.expands == true)
        #expect(harness.snippet(named: "No Keyword")?.keyword == nil)
        #expect(harness.toasts.last?.title == "Imported 5 Snippets")
        #expect(harness.toasts.last?.message == "1 snippet has placeholders that work differently here.")
    }

    @Test func theSharedPrefixIsTakenOffAnAlfredKeyword() async throws {
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.keywordPrefix] = ";"
        let harness = try await FeatureHarness.loaded([], fakes: fakes)
        let file = harness.fakes.storage.root.appending(path: "pack.alfredsnippets")
        try AlfredFixture.archive([.init("Thanks", "Thanks", keyword: "thx")], prefix: ";").write(to: file)
        try await harness.importAndConfirm([file])
        #expect(harness.snippet(named: "Thanks")?.keyword == "thx")
        #expect(harness.snippet(named: "Thanks")?.typedKeyword(prefix: ";") == ";thx", "typed as in Alfred")
    }

    @Test func theSystemsZipToolArchiveImports() throws {
        let data = try #require(Data(base64Encoded: SystemArchives.zipTool))
        let entries = try SnippetImportFile.parse(data, fileName: "Sample.alfredsnippets")
        #expect(entries.map(\.entry.name) == ["Thanks", "Stamp"])
        #expect(entries.map(\.entry.keyword) == [";thx", ";stamp"])
        #expect(entries.map(\.entry.expands) == [true, false])
        #expect(entries[1].entry.text == "{date} {clipboard}")
        #expect(entries.allSatisfy { $0.entry.collection == "Sample" })
    }

    @Test func oddFilesInAnAlfredArchive() throws {
        let notSnippet = ZipBuilder.File("other.json", text: #"{"something": "else"}"#)
        let broken = ZipBuilder.File("broken.json", text: "{ nope")
        let icon = ZipBuilder.File("icon.png", Data([0x89, 0x50, 0x4E, 0x47]), method: 0)
        let good = ZipBuilder.File("good.json", AlfredFixture.Snippet("Good", "g", keyword: "gg").json)
        let entries = try SnippetImportFile.parse(
            ZipBuilder([notSnippet, broken, icon, good]).build(), fileName: "odd.alfredsnippets")
        #expect(entries.map(\.entry.name) == [nil, nil, "Good"], "two entries that are not valid, the icon unread")

        // A plist that is not settings is ignored; one with settings of the wrong type too.
        let plist = ZipBuilder.File("info.plist", text: "not a plist")
        let withPlist = try SnippetImportFile.parse(ZipBuilder([good, plist]).build(), fileName: "x.alfredsnippets")
        #expect(withPlist.map(\.entry.keyword) == ["gg"])

        // An archive with no snippet in it is not a snippets file.
        #expect(throws: SnippetImportFile.Failure.notSnippets) {
            try SnippetImportFile.parse(ZipBuilder([icon]).build(), fileName: "empty.alfredsnippets")
        }
        #expect(throws: SnippetImportFile.Failure.notSnippets) {
            try SnippetImportFile.parse(ZipBuilder([]).build(), fileName: "empty.alfredsnippets")
        }
    }

    @Test func aHostileArchiveImportsNothingAndSaysWhy() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        let good = ZipBuilder.File("good.json", AlfredFixture.Snippet("Good", "g").json)
        var link = ZipBuilder.File("link.json", Data("/etc/hosts".utf8), method: 0)
        link.externalAttributes = 0o120777 << 16
        var inflated = ZipBuilder.File(
            "big.json", AlfredFixture.Snippet("Big", String(repeating: "b", count: 5_000)).json)
        inflated.declaredSize = 100
        var encrypted = ZipBuilder.File("secret.json", text: "{}", method: 0)
        encrypted.flags = 1
        let cases: [(ZipBuilder, String)] = [
            (
                ZipBuilder([good, .init("../escape.json", text: "{}")]),
                "The archive holds “../escape.json”, which is a folder, a link or a file inside a folder. "
                    + "Nothing was imported."
            ),
            (
                ZipBuilder([good, link]),
                "The archive holds “link.json”, which is a folder, a link or a file inside a folder. "
                    + "Nothing was imported."
            ),
            (ZipBuilder([good, inflated]), "The archive is damaged. Nothing was imported."),
            (
                ZipBuilder([encrypted]),
                "The archive is encrypted or compressed in a way that cannot be read here. Nothing was imported."
            ),
        ]
        let file = harness.fakes.storage.root.appending(path: "hostile.alfredsnippets")
        for (builder, message) in cases {
            try builder.build().write(to: file)
            harness.fakes.fileDialogs.filesToChoose = [file]
            try await harness.run(SnippetIDs.importCommand)
            #expect(harness.page == nil)
            #expect(harness.toasts.last?.title == "Could Not Import hostile.alfredsnippets")
            #expect(harness.toasts.last?.message == message)
        }
        // Cut short, the archive has no end record.
        var cut = ZipBuilder([good]).build()
        cut.removeLast(10)
        try cut.write(to: file)
        try await harness.run(SnippetIDs.importCommand)
        #expect(harness.toasts.last?.message == "The archive is damaged. Nothing was imported.")
        #expect(harness.library.index.snippets.map(\.name) == ["Greeting"])
    }
}
