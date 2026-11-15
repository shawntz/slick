import Foundation
import Kit
import KitTesting
import Testing

@testable import Scripts

/// Discovery on the real file system, in the fake storage's temporary folder, with the fake file
/// watcher. Nothing outside that folder is read.
@Suite("Discovery", .timeLimit(.minutes(1)))
@MainActor
struct DiscoveryTests {
    private let fakes = FakeServices()
    private let bench: ScriptsBench

    init() {
        bench = ScriptsBench(library: FileScriptLibrary(), fakes: fakes)
    }

    private var folder: URL { bench.folder }

    private func write(_ text: String, _ name: String, in folder: URL? = nil) throws {
        let folder = folder ?? self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }

    private func extraFolder(_ name: String) throws -> URL {
        let url = fakes.storage.root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func scriptsInTheDefaultFolderBecomeCommandsWithStableIDs() async throws {
        try write(Fixture.script(title: "Say Hello"), "say-hello.sh")
        try write(Fixture.script("silent", title: "Café Time", prefix: Fixture.own), "café time.zsh")
        await bench.start()
        #expect(bench.scriptCommands.map(\.title) == ["Café Time", "Say Hello"])
        let ids = bench.scriptCommands.map(\.id)
        #expect(ids == [bench.id("café time.zsh"), bench.id("say-hello.sh")])
        #expect(ids[0].hasPrefix("script.cafe-time-"))
        #expect(ids[1].hasPrefix("script.say-hello-"))
        #expect(bench.harness.issues.isEmpty)

        // A relaunch: a new feature over the same folder gives the same IDs.
        let relaunched = ScriptsBench(library: FileScriptLibrary(), fakes: fakes)
        await relaunched.start()
        #expect(relaunched.scriptCommands.map(\.id) == ids)
    }

    @Test func activationCreatesTheDefaultFolderAndWatchesIt() async throws {
        await bench.start()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(fakes.fileWatcher.watchedDirectories.map(ScriptPath.key) == [ScriptPath.key(folder)])
        #expect(bench.scriptCommands.isEmpty)
        #expect(bench.feature.status == nil)
    }

    @Test func skipsFilesThatAreNotScriptCommands() async throws {
        try write(Fixture.script(title: "Kept"), "kept.sh")
        try write(Fixture.script(title: "Hidden"), ".hidden.sh")
        try write(Fixture.script(title: "Template"), "greet.template.sh")
        try write("#!/bin/bash\necho a helper\n", "helper.sh")
        try write("A note about these scripts.\n", "README.md")
        try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        try write(Fixture.script(title: "Nested"), "nested.sh", in: folder.appending(path: "nested"))
        try (Data(Fixture.script(title: "Binary").utf8) + Data([0, 1, 2])).write(
            to: folder.appending(path: "binary.sh"))
        await bench.start()
        #expect(bench.scriptCommands.map(\.title) == ["Kept"])
        #expect(bench.feature.catalog.entries.map(\.title) == ["Kept"])
    }

    @Test func aScriptThatAppearsOrDisappearsUpdatesTheCommands() async throws {
        try write(Fixture.script(title: "First"), "first.sh")
        await bench.start()
        let signal = try #require(bench.feature.declarationChanges)
        let before = signal.generation

        try write(Fixture.script(title: "Second"), "second.sh")
        fakes.fileWatcher.simulateChange([folder.appending(path: "second.sh")])
        try await bench.harness.settle()
        #expect(bench.scriptCommands.map(\.title) == ["First", "Second"])
        #expect(signal.generation == before + 1)

        try FileManager.default.removeItem(at: folder.appending(path: "first.sh"))
        fakes.fileWatcher.simulateChange([folder.appending(path: "first.sh")])
        try await bench.harness.settle()
        #expect(bench.scriptCommands.map(\.title) == ["Second"])
        #expect(signal.generation == before + 2)

        // A change that leaves the scripts as they were sends nothing.
        fakes.fileWatcher.simulateChange([folder.appending(path: "notes.txt")])
        try await bench.harness.settle()
        #expect(signal.generation == before + 2)
    }

    @Test func editingAHeaderUpdatesTheCommandAndKeepsItsID() async throws {
        try write(Fixture.script(title: "Old Title"), "tool.sh")
        await bench.start()
        let id = try #require(bench.scriptCommands.first?.id)
        try write(Fixture.script("silent", title: "New Title"), "tool.sh")
        fakes.fileWatcher.simulateChange([folder.appending(path: "tool.sh")])
        try await bench.harness.settle()
        #expect(bench.scriptCommands.map(\.title) == ["New Title"])
        #expect(bench.scriptCommands.map(\.id) == [id])
    }

    @Test func aBrokenScriptIsNotACommandAndShowsItsProblem() async throws {
        try write(Fixture.script(title: "Good"), "good.sh")
        try write(Fixture.script("verbose", title: "Broken"), "broken.sh")
        await bench.start()
        #expect(bench.scriptCommands.map(\.title) == ["Good"])
        #expect(
            bench.feature.status
                == FeatureStatus(.warning, Strings.problemsStatus(1), message: Strings.problemsStatusMessage))

        try await bench.harness.run("manage")
        #expect(bench.harness.rows.map(\.title) == ["Broken", "Good"])
        try bench.harness.select(title: "Broken")
        #expect(bench.harness.selectedRow?.accessories == [.tag(Strings.tagProblem, color: .red)])
        let detail = try #require(try await bench.harness.loadDetail())
        guard case .markdown(let text) = detail.body else {
            Issue.record("expected Markdown")
            return
        }
        #expect(text.contains(Strings.problemLine(.error(Strings.Problem.mode("verbose"), line: 4))))
        #expect(bench.harness.actions().map(\.id) == ["edit-with", "reveal", "copy-path"])
        #expect(bench.harness.issues.isEmpty)
    }

    @Test func scriptsInANewFolderStayOffUntilTheFolderIsTurnedOn() async throws {
        let extra = try extraFolder("Team Scripts")
        try write(Fixture.script(title: "Deploy"), "deploy.sh", in: extra)
        await bench.start()
        bench.harness.context.settings[ScriptsSettings.folders] = [extra.path]
        try await bench.harness.settle()

        #expect(bench.scriptCommands.isEmpty, "a newly added folder is listed but off")
        #expect(bench.feature.status == FeatureStatus(.info, Strings.offStatus(1), message: Strings.offStatusMessage))
        #expect(
            Set(fakes.fileWatcher.watchedDirectories.map(ScriptPath.key)) == [
                ScriptPath.key(folder), ScriptPath.key(extra),
            ])
        try await bench.harness.run("manage")
        #expect(bench.harness.sections.map(\.title) == ["Team Scripts"])
        #expect(bench.harness.selectedRow?.accessories.contains(.tag(Strings.tagOff, color: .gray)) == true)
        #expect(bench.harness.actions().map(\.id).first == "turn-on-folder")

        // Turning the folder on asks first, and declining leaves it off.
        bench.harness.confirmationAnswer = false
        try await bench.harness.perform("turn-on-folder")
        #expect(bench.harness.confirmations.map(\.title) == [Strings.turnOnFolderQuestion("Team Scripts")])
        #expect(bench.scriptCommands.isEmpty)

        bench.harness.confirmationAnswer = true
        try await bench.harness.perform("turn-on-folder")
        try await bench.harness.settle()
        #expect(bench.scriptCommands.map(\.title) == ["Deploy"])
        #expect(bench.harness.context.settings[ScriptsSettings.enabledFolders] == [ScriptPath.key(extra)])
        #expect(bench.harness.toasts.last?.title == Strings.folderTurnedOn("Team Scripts"))
        #expect(bench.feature.status == nil)
        #expect(bench.harness.rows.first?.accessories.contains(.tag(Strings.tagOff, color: .gray)) == false)
    }

    @Test func removingAFolderForgetsThatItWasOn() async throws {
        let extra = try extraFolder("Mine")
        try write(Fixture.script(title: "Backup"), "backup.sh", in: extra)
        await bench.start()
        let settings = bench.harness.context.settings
        settings[ScriptsSettings.folders] = [extra.path + "/"]
        settings[ScriptsSettings.enabledFolders] = [extra.path]
        try await bench.harness.settle()
        #expect(bench.scriptCommands.map(\.title) == ["Backup"])

        settings[ScriptsSettings.folders] = []
        try await bench.harness.settle()
        #expect(bench.scriptCommands.isEmpty)
        #expect(settings[ScriptsSettings.enabledFolders].isEmpty)

        // Added again later, it starts off.
        settings[ScriptsSettings.folders] = [extra.path]
        try await bench.harness.settle()
        #expect(bench.scriptCommands.isEmpty)
    }

    @Test func aMissingFolderShowsInTheStatus() async throws {
        await bench.start()
        let missing = fakes.storage.root.appending(path: "gone", directoryHint: .isDirectory)
        bench.harness.context.settings[ScriptsSettings.folders] = [missing.path, "relative/path"]
        try await bench.harness.settle()
        #expect(bench.feature.status?.level == .warning)
        #expect(bench.feature.status?.title == Strings.missingFolderStatus(ScriptPath.key(missing)))
        #expect(bench.feature.catalog.folders.count == 2, "a relative path is ignored")
    }

    @Test func settingsListTheAddedFoldersAndTheInlineScripts() async throws {
        let extra = try extraFolder("More")
        try write(Fixture.script("inline", title: "Clock", extra: ["refreshTime 1m"]), "clock.sh")
        try write(Fixture.script(title: "Other"), "other.sh")
        await bench.start()
        bench.harness.context.settings[ScriptsSettings.folders] = [extra.path]
        try await bench.harness.settle()
        let items = try #require(bench.feature.settingsPane).sections.flatMap(\.items)
        var choices: [String: [SettingsChoice]] = [:]
        for item in items {
            if case .multiSelect(let key, let options) = item.control { choices[key.name] = await options() }
        }
        #expect(choices["enabledFolders"]?.map(\.id) == [ScriptPath.key(extra)])
        #expect(choices["refreshingInline"]?.map(\.title) == ["Clock"])
        #expect(choices["refreshingInline"]?.map(\.id) == [bench.id("clock.sh")])
    }

    @Test func reloadReportsWhatItFound() async throws {
        try write(Fixture.script(title: "One"), "one.sh")
        try write(Fixture.script(title: "Two"), "two.sh")
        try write(Fixture.script(title: "Three", shebang: "#!python"), "three.py")
        await bench.start()
        try await bench.harness.run("reload")
        #expect(bench.harness.toasts.map(\.title) == [Strings.reloaded(commands: 2, problems: 1)])
        try await bench.harness.pressSettingsButton(Strings.reloadTitle)
        #expect(bench.harness.toasts.count == 2)
    }
}
