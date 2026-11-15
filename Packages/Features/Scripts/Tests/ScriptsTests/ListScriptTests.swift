import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// List scripts: Script Filter JSON, valid and hostile, through the fake process service.
@Suite("List scripts", .timeLimit(.minutes(1)))
@MainActor
struct ListScriptTests {
    private func bench(_ action: String? = nil, json: @escaping @Sendable (ProcessRequest) -> String) -> ScriptsBench {
        let extra = action.map { ["filterAction \($0)"] } ?? []
        let bench = ScriptsBench(files: [
            "search.sh": Fixture.script("list", title: "Search Issues", prefix: Fixture.own, extra: extra)
        ])
        bench.fakes.processes.stubScripts { .stdout(json($0)) }
        return bench
    }

    nonisolated private static let issues = #"""
        {
          "rerun": 0.5,
          "variables": {"page": 1, "PATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "bad name": "x"},
          "skipknowledge": true,
          "cache": {"seconds": 60},
          "items": [
            {"uid": "1", "title": "Crash on launch", "subtitle": "Open in browser",
             "arg": "https://example.com/issues/1",
             "icon": {"type": "fileicon", "path": "~/Applications/Example.app"},
             "mods": {"cmd": {"subtitle": "Copy the issue number", "arg": "1"},
                      "alt+shift": {"subtitle": "Not now", "valid": false},
                      "hyper": {"subtitle": "ignored"}},
             "text": {"copy": "Issue 1: Crash on launch"}},
            {"uid": "2", "title": "Notes file", "arg": "~/notes.txt", "type": "file", "quicklookurl": "~/notes.txt",
             "icon": {"type": "filetype", "path": "public.plain-text"}},
            {"title": "Plain text", "arg": ["one", "two"], "icon": {"path": "icons/text.png"}},
            {"title": "More", "valid": false, "autocomplete": "more "}
          ]
        }
        """#

    @Test func showsRowsFromTheJSON() async throws {
        let bench = bench { _ in Self.issues }
        await bench.start()
        let outcome = try await bench.harness.run(bench.id("search.sh"))
        #expect(outcome.kind == .push)
        let rows = bench.harness.rows
        #expect(rows.map(\.title) == ["Crash on launch", "Notes file", "Plain text", "More"])
        #expect(rows[0].subtitle == "Open in browser")
        #expect(
            rows[0].alternates == [
                Row.Alternate(modifiers: [.option, .shift], subtitle: "Not now"),
                Row.Alternate(modifiers: .command, subtitle: "Copy the issue number"),
            ])
        #expect(
            rows[0].icon
                == .file(path: bench.fakes.storage.homeDirectory.appending(path: "Applications/Example.app").path))
        #expect(rows[1].icon == .fileType("public.plain-text"))
        #expect(rows[2].icon == .image(path: bench.folder.appending(path: "icons/text.png").path))
        #expect(rows[1].quickLookURL?.path == bench.fakes.storage.homeDirectory.appending(path: "notes.txt").path)
        #expect(rows[3].completion == "more ")
        #expect(rows.map(\.memory) == [.never, .never, .never, .never])
        #expect(Set(rows.map(\.id)).count == 4)
        #expect(bench.harness.page?.refreshAfter == .milliseconds(500))
        #expect(bench.harness.page?.notice == nil)
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func returnOpensALinkAndModifiersActOnTheirOwnArgument() async throws {
        let bench = bench { _ in Self.issues }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        let actions = bench.harness.actions()
        #expect(
            actions.map(\.title) == [
                Strings.openArgument, Strings.withModifiers(Strings.copyArgument, .command), Strings.copyArgument,
            ])
        #expect(actions.map(\.shortcut) == [nil, .secondaryAction, .copy])
        try await bench.harness.performPrimary()
        #expect(bench.fakes.workspace.opened == [URL(string: "https://example.com/issues/1")!])
        try await bench.harness.performSecondary()
        #expect(bench.fakes.pasteboard.copiedTexts == ["1"])
        try await bench.harness.perform("copy-text")
        #expect(bench.fakes.pasteboard.copiedTexts == ["1", "Issue 1: Crash on launch"])
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func fileRowsOpenRevealAndPreview() async throws {
        let bench = bench { _ in Self.issues }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        try bench.harness.select(title: "Notes file")
        #expect(bench.harness.actions().map(\.id) == ["open", "copy-text", "quick-look", "reveal"])
        #expect(
            bench.harness.selectedRow?.represents?.text
                == bench.fakes.storage.homeDirectory.appending(path: "notes.txt").path)
        try bench.harness.select(title: "Plain text")
        #expect(bench.harness.actions().map(\.id) == ["copy"], "text is copied, one argument per line")
        try await bench.harness.performPrimary()
        #expect(bench.fakes.pasteboard.copiedTexts == ["one\ntwo"])
    }

    @Test func anInvalidRowCompletesItsText() async throws {
        let bench = bench { _ in Self.issues }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        try bench.harness.select(title: "More")
        #expect(bench.harness.actions().map(\.id) == ["complete", "copy-text"])
        try await bench.harness.performPrimary()
        #expect(bench.harness.queryChanges == ["more "])
    }

    @Test func runsAgainForEachQueryWithItsVariables() async throws {
        let bench = bench { request in
            let query = Fixture.scriptArguments(request).first ?? ""
            let page = request.environment["page"] ?? "0"
            return #"{"variables": {"page": "\#(Int(page)! + 1)"}, "items": [{"title": "\#(query) on page \#(page)"}]}"#
        }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.rows.map(\.title) == ["on page 0"], "titles are trimmed")
        try await bench.harness.setQuery("crash")
        #expect(bench.harness.rows.map(\.title) == ["crash on page 1"])
        #expect(bench.harness.rows.first?.titleHighlights == [0..<5])
        try await bench.harness.refresh()
        #expect(bench.harness.rows.map(\.title) == ["crash on page 2"])
        let runs = bench.fakes.processes.runs
        #expect(runs.map(Fixture.scriptArguments) == [[""], ["crash"], ["crash"]])
        #expect(runs.allSatisfy { $0.environment["PATH"] == ScriptsSettings.defaultSearchPath })
        #expect(ScriptListSource.debounce == .milliseconds(120))
    }

    @Test func unsafeVariablesNeverReachTheNextRun() async throws {
        let bench = bench { _ in Self.issues }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        try await bench.harness.setQuery("x")
        let environment = try #require(bench.fakes.processes.runs.last?.environment)
        #expect(environment == ["PATH": ScriptsSettings.defaultSearchPath, "page": "1"])
    }

    @Test func aFallbackOpensTheListWithTheTypedText() async throws {
        let bench = bench { _ in #"{"items": []}"# }
        await bench.start()
        let command = try bench.harness.command(bench.id("search.sh"))
        #expect(command.arguments.isEmpty)
        #expect(command.fallback != nil)
        try await bench.harness.runFallback(command.id, text: "login bug")
        #expect(bench.harness.page?.query == "login bug")
        #expect(bench.fakes.processes.runs.map(Fixture.scriptArguments) == [["login bug"]])
        #expect(bench.harness.page?.emptyState?.title == Strings.noResults)
    }

    @Test func theFilterActionCanCopyOrPaste() async throws {
        let json = #"{"items": [{"title": "Token", "arg": "https://example.com/t"}]}"#
        let copying = bench("copy") { _ in json }
        await copying.start()
        try await copying.harness.run(copying.id("search.sh"))
        try await copying.harness.performPrimary()
        #expect(copying.fakes.pasteboard.copiedTexts == ["https://example.com/t"])
        #expect(copying.harness.actions().map(\.id) == ["copy"], "no second copy of the same text")

        let pasting = bench("paste") { _ in json }
        await pasting.start()
        try await pasting.harness.run(pasting.id("search.sh"))
        #expect(pasting.harness.actions().first?.requires == [.accessibility])
        try await pasting.harness.performPrimary()
        #expect(pasting.fakes.pasteboard.pastedTexts == ["https://example.com/t"])
        #expect(pasting.harness.issues.isEmpty)
    }

    @Test func autoNeverOpensAnUnusualScheme() async throws {
        let bench = bench { _ in #"{"items": [{"title": "Run", "arg": "x-unknown-app://do?thing=1"}]}"# }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.actions().first?.id == "copy")
    }

    @Test func aFailingScriptShowsItsErrorOutput() async throws {
        let bench = ScriptsBench(files: ["search.sh": Fixture.script("list", title: "Search Issues")])
        bench.fakes.processes.stubScripts([
            "search.sh": FakeProcessOutput(events: [.stderr(Data("Traceback\nKeyError: 'token'\n".utf8))], exitCode: 1)
        ])
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.rows.isEmpty)
        let empty = try #require(bench.harness.page?.emptyState)
        #expect(empty.title == Strings.listFailed("Search Issues"))
        #expect(empty.message == "Traceback\nKeyError: 'token'")
        #expect(bench.harness.actions().map(\.id) == ["show-output"])
        try await bench.harness.perform("show-output")
        #expect(bench.harness.detail?.body == .text("Traceback\nKeyError: 'token'\n", monospaced: true))
    }

    // MARK: - Hostile output

    /// Output that is not a usable list, and the message the page shows.
    nonisolated static let unusable: [(String, String)] = [
        ("", Strings.emptyOutput),
        (" \n\t ", Strings.emptyOutput),
        ("not json", Strings.notJSON),
        ("null", Strings.noItems),
        ("[]", Strings.noItems),
        (#"{"items": 5}"#, Strings.noItems),
        (#"{"items": [1, 2"#, Strings.notJSON),
        (#"{"items": []} trailing"#, Strings.notJSON),
        (String(repeating: "[", count: 100_000), Strings.tooDeep),
        (#"{"items": [{"title": "a", "deep": "#, Strings.notJSON),
        ("{" + String(repeating: #""a":{"#, count: 40) + "}", Strings.tooDeep),
    ]

    @Test(arguments: unusable)
    func unusableOutputShowsAnError(output: String, message: String) async throws {
        let bench = bench { _ in output }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.rows.isEmpty)
        #expect(bench.harness.page?.emptyState?.message == message)
    }

    @Test func invalidUTF8IsNotJSON() throws {
        let source = FilterOutput.Source(
            namespace: "scripts", commandID: "script.x", folder: URL(filePath: "/s"), home: URL(filePath: "/h"),
            query: "")
        #expect(throws: FilterOutput.Failure.invalid) {
            try FilterOutput.page(from: Data([0x7B, 0x22, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D]), source: source)
        }
    }

    @Test func wrongTypesAndMissingTitlesAreLeftOut() async throws {
        let bench = bench { _ in
            #"""
            {"rerun": "fast", "variables": [1, 2],
             "items": [
               {"title": 7}, {"subtitle": "no title"}, "a string", null, {"title": "   "},
               {"uid": "same", "title": "First", "subtitle": {"nested": true}, "arg": {"a": 1}, "mods": "cmd",
                "valid": "yes", "icon": "x.png", "text": "copy me", "quicklookurl": 5, "type": ["file"]},
               {"uid": "same", "title": "Second", "arg": 42, "mods": {"cmd": "nope", "ctrl": {"arg": ["a", 3, "b"]}}}
             ]}
            """#
        }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.rows.map(\.title) == ["First", "Second"])
        #expect(bench.harness.rows[0].subtitle == nil)
        #expect(bench.harness.rows[0].icon == nil)
        #expect(bench.harness.rows[0].id != bench.harness.rows[1].id)
        #expect(bench.harness.page?.refreshAfter == nil)
        #expect(bench.harness.page?.notice?.title == Strings.skippedItems(5))
        try bench.harness.select(title: "Second")
        try await bench.harness.perform("modifier." + KeyCombo(.return, .control).description)
        #expect(bench.fakes.pasteboard.copiedTexts == ["a\nb"])
        try bench.harness.select(title: "Second")
        try await bench.harness.performPrimary()
        #expect(bench.fakes.pasteboard.copiedTexts.last == "42")
    }

    @Test func longOutputIsCutToSafeSizes() async throws {
        let longTitle = String(repeating: "x", count: 5000)
        let items = (0..<1500).map { #"{"title": "Item \#($0)"}"# }.joined(separator: ",")
        let bench = bench { request in
            Fixture.scriptArguments(request).first == "long"
                ? #"{"rerun": 99, "items": [{"title": "\#(longTitle)"}]}"#
                : #"{"rerun": 0.01, "items": [\#(items)]}"#
        }
        await bench.start()
        try await bench.harness.run(bench.id("search.sh"))
        #expect(bench.harness.rows.count == FilterOutput.maximumItems)
        #expect(bench.harness.page?.notice?.title == Strings.truncatedItems(shown: 1000, total: 1500))
        #expect(bench.harness.page?.refreshAfter == .milliseconds(100))
        try await bench.harness.setQuery("long")
        #expect(bench.harness.rows.first?.title.count == FilterOutput.maximumTitleLength)
        #expect(bench.harness.page?.refreshAfter == .seconds(5))
    }

    @Test func jsonKeepsBooleansAndNumbersApart() throws {
        let value = try JSONValue.decode(
            Data(#"{"t": true, "f": false, "one": 1, "zero": 0, "pi": 3.5, "s": "1", "n": null, "a": [true]}"#.utf8),
            maximumDepth: 4)
        let object = try #require(value.object)
        #expect(object["t"] == .bool(true))
        #expect(object["f"] == .bool(false))
        #expect(object["one"] == .number(1))
        #expect(object["zero"] == .number(0))
        #expect(object["pi"] == .number(3.5))
        #expect(object["s"] == .string("1"))
        #expect(object["n"] == .null)
        #expect(object["a"] == .array([.bool(true)]))
        #expect(object["one"]?.scalarText == "1")
        #expect(object["pi"]?.scalarText == "3.5")
        #expect(JSONValue.depth(of: Data(#"{"a": "[[[[", "b": [{"c": "\"]"}]}"#.utf8), limit: 10) == 3)
    }

    @Test func variableNamesAreChecked() {
        for name in ["page", "_cursor", "Query2", "alfred_workflow_cache"] {
            #expect(FilterOutput.isAllowedVariable(name), "\(name)")
        }
        for name in ["", "PATH", "path", "HOME", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "2fast", "a-b", "a b", "é"] {
            #expect(!FilterOutput.isAllowedVariable(name), "\(name)")
        }
        #expect(FilterOutput.keyModifiers("cmd+alt") == [.command, .option])
        #expect(FilterOutput.keyModifiers("fn") == .function)
        #expect(FilterOutput.keyModifiers("cmd+hyper") == nil)
        #expect(FilterOutput.keyModifiers("") == nil)
    }
}
