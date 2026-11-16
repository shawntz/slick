import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Settings", .timeLimit(.minutes(1)))
@MainActor
struct SettingsTests {
    @Test func thePaneHasTheShellTheFolderTheLimitAndHistory() throws {
        let bench = Bench()
        let pane = try #require(bench.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Running Commands", "History"])
        #expect(
            pane.sections.flatMap(\.items).map(\.title) == [
                "Shell", "Working folder", "Choose Working Folder…", "Keep output up to", "Keep history",
                "Clear History",
            ])
        let footer = try #require(pane.sections.last?.footer)
        #expect(footer.contains(Brand.name) && footer.contains("history.json") && footer.contains("200"))
        #expect(ShellChoice.allCases.map(Strings.Settings.shellOption) == ["Login Shell", "zsh", "bash", "sh"])
        #expect(ShellSettings.shell.defaultValue == .login)
        #expect(ShellSettings.workingFolder.defaultValue.isEmpty)
        #expect(ShellSettings.keepsHistory.defaultValue)
    }

    @Test func chooseWorkingFolderStoresItUnderHome() async throws {
        let bench = Bench()
        await bench.start()
        let settings = bench.feature.context.settings
        bench.fakes.fileDialogs.filesToChoose = [bench.home.appending(path: "code/site", directoryHint: .isDirectory)]
        try await bench.harness.pressSettingsButton("Choose Working Folder…")
        #expect(settings[ShellSettings.workingFolder] == "~/code/site")
        #expect(bench.fakes.fileDialogs.openRequests.first?.canChooseDirectories == true)
        #expect(bench.fakes.fileDialogs.openRequests.first?.canChooseFiles == false, "folders only")
        #expect(bench.harness.toasts.last?.title == "Working Folder Chosen")

        bench.fakes.fileDialogs.filesToChoose = [URL(filePath: "/srv/www", directoryHint: .isDirectory)]
        try await bench.harness.pressSettingsButton("Choose Working Folder…")
        #expect(settings[ShellSettings.workingFolder] == "/srv/www")

        bench.fakes.fileDialogs.filesToChoose = []
        try await bench.harness.pressSettingsButton("Choose Working Folder…")
        #expect(settings[ShellSettings.workingFolder] == "/srv/www", "cancel changes nothing")

        bench.fakes.fileDialogs.filesToChoose = [URL(filePath: "/srv/www/index.html", directoryHint: .notDirectory)]
        await #expect(throws: ActionFailure.self) {
            try await bench.harness.pressSettingsButton("Choose Working Folder…")
        }
        #expect(settings[ShellSettings.workingFolder] == "/srv/www")
    }

    @Test func folderSettingsReadAsFolders() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func folder(_ setting: String) -> String? {
            try? RunSetup.folder(from: setting, home: home).get().path(percentEncoded: false)
        }
        #expect(folder("") == "/Users/someone/")
        #expect(folder("  ~  ") == "/Users/someone/")
        #expect(folder("~/") == "/Users/someone/")
        #expect(folder("~/src/app") == "/Users/someone/src/app/")
        #expect(folder("/opt/x") == "/opt/x/")
        #expect(folder("src") == nil)
        #expect(folder("~other") == nil)
        #expect(folder("/tmp/a\nb") == nil)
        #expect(RunSetup.settingValue(for: home, home: home) == "~")
        #expect(RunSetup.settingValue(for: home.appending(path: "a b"), home: home) == "~/a b")
        #expect(RunSetup.settingValue(for: URL(filePath: "/Users/someoneelse"), home: home) == "/Users/someoneelse")
        #expect(RunSetup.settingValue(for: URL(filePath: "/"), home: home) == "/")
    }

    @Test func clearHistoryInSettingsAsksFirst() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        bench.harness.confirmationAnswer = false
        try await bench.harness.pressSettingsButton("Clear History")
        #expect(bench.harness.confirmations.last?.title == "Clear Shell History?")
        #expect(bench.feature.history.entries.count == 1)
        bench.harness.confirmationAnswer = true
        try await bench.harness.pressSettingsButton("Clear History")
        #expect(bench.feature.history.entries.isEmpty)
        #expect(bench.harness.toasts.last?.title == "Cleared Shell History")
    }

    @Test func aStoredValueOfTheWrongKindReadsAsTheDefault() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        bench.fakes.settings.set(.string("tcsh-or-anything"), for: "shell.shell")
        bench.fakes.settings.set(.int(5), for: "shell.outputLimit")
        await bench.start()
        #expect(bench.feature.context.settings[ShellSettings.shell] == .login)
        #expect(bench.feature.context.settings[ShellSettings.outputLimit] == .twoMegabytes)
        try await bench.harness.run("run", arguments: ["command": "ls"])
        #expect(bench.fakes.processes.runs.first?.executable.path(percentEncoded: false) == "/bin/zsh")
    }
}
