import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Create Script Command, Open Script Folder, Reload Scripts, Manage Script Commands, settings and
/// the declarations the host checks.
@Suite("Commands", .timeLimit(.minutes(1)))
@MainActor
struct CommandsTests {
    @Test func declaresFourCommandsAndAValidManifest() async throws {
        let bench = ScriptsBench()
        await bench.start()
        #expect(bench.feature.commands.map(\.id) == ["create", "open-folder", "reload", "manage"])
        #expect(
            bench.feature.commands.map(\.title) == [
                "Create Script Command", "Open Script Folder", "Reload Scripts", "Manage Script Commands",
            ])
        #expect(ScriptsFeature.manifest.id == "scripts")
        #expect(ScriptsFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(ScriptsFeature.manifest.permissions.allSatisfy { $0.reason.first?.isUppercase == true })
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func aWebIconShowsOnlyAfterTheUserAllowsIt() async throws {
        let bench = ScriptsBench(files: [
            "web.sh": Fixture.script(
                title: "Web Icon", extra: ["icon https://example.com/a.png", "iconDark https://example.com/b.png"])
        ])
        await bench.start()
        #expect(ScriptsSettings.remoteIcons.defaultValue == false)
        #expect(try #require(bench.scriptCommands.first).icon == .symbol("terminal"))
        try await bench.harness.run("manage")
        #expect(bench.harness.rows.first?.icon == .symbol("terminal"))

        let declarations = try #require(bench.feature.declarationChanges).generation
        bench.harness.context.settings[ScriptsSettings.remoteIcons] = true
        try await bench.harness.settle()
        #expect(try #require(bench.feature.declarationChanges).generation > declarations)
        #expect(
            try #require(bench.scriptCommands.first).icon
                == .adaptive(
                    light: .remote(URL(string: "https://example.com/a.png")!),
                    dark: .remote(URL(string: "https://example.com/b.png")!)))
        #expect(
            bench.harness.rows.first?.icon
                == .adaptive(
                    light: .remote(URL(string: "https://example.com/a.png")!),
                    dark: .remote(URL(string: "https://example.com/b.png")!)), "the open list follows")
        #expect(bench.fakes.http.requests.isEmpty, "the feature itself downloads nothing")
    }

    @Test func createsAScriptFromATemplateAndItBecomesACommand() async throws {
        let library = MemoryScriptLibrary()
        let bench = ScriptsBench(library: library)
        await bench.start()
        try await bench.harness.run("create")
        try bench.harness.fill("title", text: "  Résumé Search ")
        try bench.harness.fill("language", text: ScriptLanguage.python.rawValue)
        try bench.harness.fill("mode", text: ScriptMode.list.rawValue)
        try bench.harness.fill("packageName", text: "Work")
        let outcome = try await bench.harness.submit()
        #expect(outcome.kind == .close(hud: .success(Strings.created("resume-search.py"))))

        let url = bench.folder.appending(path: "resume-search.py")
        let text = try #require(library.contents(of: url))
        #expect(text.hasPrefix("#!/usr/bin/env python3\n"))
        let parsed = HeaderParser.parse(text)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.metadata?.title == "Résumé Search")
        #expect(parsed.metadata?.mode == .list)
        #expect(parsed.metadata?.packageName == "Work")
        #expect(bench.fakes.workspace.revealed.map(\.path) == [url.path])
        let command = try #require(bench.scriptCommands.first)
        #expect(command.title == "Résumé Search")
        #expect(command.subtitle == "Work")
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func createChecksTheTitleAndRefusesToOverwrite() async throws {
        let library = MemoryScriptLibrary()
        let bench = ScriptsBench(library: library)
        await bench.start()
        try await bench.harness.run("create")
        try bench.harness.fill("title", text: "!!!")
        await #expect(throws: HarnessError.invalidForm(["title": FieldError(Strings.titleNeedsLetters)])) {
            try await bench.harness.submit()
        }
        library.write("echo old", at: bench.folder.appending(path: "hello.sh"))
        try bench.harness.fill("title", text: "Hello")
        await #expect(throws: HarnessError.invalidForm(["title": FieldError(Strings.fileExists("hello.sh"))])) {
            try await bench.harness.submit()
        }
        #expect(library.contents(of: bench.folder.appending(path: "hello.sh")) == "echo old")
    }

    @Test func createOffersOnlyFoldersThatAreOn() async throws {
        let bench = ScriptsBench()
        await bench.start()
        bench.harness.context.settings[ScriptsSettings.folders] = ["/scripts/team", "/scripts/mine"]
        bench.harness.context.settings[ScriptsSettings.enabledFolders] = ["/scripts/mine"]
        try await bench.harness.settle()
        try await bench.harness.run("create")
        guard case .form(let form) = bench.harness.page?.page,
            case .dropdown(let options, _) = form.fields.first(where: { $0.id == "folder" })?.kind
        else {
            Issue.record("expected a folder dropdown")
            return
        }
        #expect(options.map(\.title) == [Strings.defaultFolderName, "mine"])
        try bench.harness.fill("title", text: "Mine")
        try bench.harness.fill("folder", text: "/scripts/mine")
        try await bench.harness.submit()
        #expect(await bench.library.exists(URL(filePath: "/scripts/mine/mine.sh")))
    }

    /// Every language and mode the form offers makes a script that parses with no problems.
    @Test(arguments: ScriptLanguage.allCases)
    func everyTemplateParses(language: ScriptLanguage) throws {
        for mode in ScriptMode.allCases {
            let text = ScriptTemplate.render(title: "Template Check", language: language, mode: mode, packageName: nil)
            let parsed = HeaderParser.parse(text)
            #expect(parsed.problems.isEmpty, "\(language) \(mode): \(parsed.problems)")
            #expect(parsed.metadata?.effectiveMode == mode)
            let name = try #require(ScriptTemplate.fileName(for: "Template Check", language: language))
            #expect(throws: Never.self) {
                try Interpreter.resolve(header: text, fileExtension: (name as NSString).pathExtension).get()
            }
        }
    }

    @Test func openScriptFolderCreatesAndOpensTheDefaultFolder() async throws {
        let bench = ScriptsBench()
        let outcome = try await bench.harness.run("open-folder")
        #expect(outcome.kind == .close(hud: nil))
        #expect(bench.fakes.workspace.opened.map(\.path) == [bench.folder.path])
        #expect(await bench.library.exists(bench.folder))
    }

    @Test func manageListsEveryScriptByFolderAndRunsOne() async throws {
        let bench = ScriptsBench(files: [
            "a.sh": Fixture.script("inline", title: "Clock", extra: ["refreshTime 1m"]),
            "b.sh": Fixture.script(title: "Warned", extra: ["colour blue"]),
        ])
        bench.fakes.processes.stubScripts(["a.sh": .stdout("9:30\n")])
        await bench.start()
        try await bench.harness.run("manage")
        #expect(bench.harness.sections.map(\.title) == [Strings.defaultFolderName])
        #expect(bench.harness.rows.map(\.title) == ["Clock", "Warned"])
        #expect(bench.harness.rows[0].accessories == [.tag(Strings.modeName(.inline))])
        #expect(
            bench.harness.rows[1].accessories == [
                .tag(Strings.modeName(.compact)), .tag(Strings.tagWarning, color: .orange),
            ])
        #expect(
            bench.harness.actions().map(\.id).first == "run."
                + ItemID.command(feature: "scripts", command: bench.id("a.sh")).rawValue)
        let outcome = try await bench.harness.performPrimary()
        #expect(outcome.kind == .run(ItemID.command(feature: "scripts", command: bench.id("a.sh")), arguments: [:]))

        try await bench.harness.setQuery("warn")
        #expect(bench.harness.rows.map(\.title) == ["Warned"])
        let detail = try #require(try await bench.harness.loadDetail())
        #expect(detail.metadata.contains(.label(Strings.detailCommandID, value: bench.id("b.sh"))))
        #expect(detail.metadata.contains(.label(Strings.detailInterpreter, value: "/bin/bash")))
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func manageOffersToCreateWhenThereAreNoScripts() async throws {
        let bench = ScriptsBench()
        await bench.start()
        try await bench.harness.run("manage")
        #expect(bench.harness.rows.isEmpty)
        #expect(bench.harness.page?.emptyState?.title == Strings.noScriptsTitle)
        #expect(bench.harness.actions().map(\.title) == [Strings.createTitle, Strings.openFolderTitle])
        try await bench.harness.performPrimary()
        #expect(bench.harness.page?.page.isForm == true)
    }

    @Test func settingsSayThatScriptsRunWithTheUsersRights() async throws {
        let bench = ScriptsBench()
        let pane = try #require(bench.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        #expect(items.first?.title == Strings.safetyNote)
        #expect(
            items.compactMap(\.control.key?.name) == [
                "folders", "enabledFolders", "remoteIcons", "timeout", "outputLimit", "searchPath", "refreshingInline",
            ])
    }

    @Test func isolatedRunsUseSyntheticScripts() async throws {
        let fakes = FakeServices()
        let harness = FeatureHarness(ScriptsFeature.self, environment: .scenario, fakes: fakes)
        await harness.activate()
        await harness.feature.scanned()
        #expect(
            harness.feature.commands.filter { $0.id.hasPrefix("script.") }.map(\.title) == [
                "Say Hello", "Search Colors", "Uptime",
            ])
        #expect(!FileManager.default.fileExists(atPath: fakes.storage.root.path), "nothing was written to disk")
        #expect(harness.issues.isEmpty)
    }
}

extension Page {
    var isForm: Bool {
        if case .form = self { return true }
        return false
    }
}
