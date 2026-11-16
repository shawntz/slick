import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

/// What Shell leaves on disk and what the settings say about a command's reach. Nothing here starts
/// a process: the bench's process service is a fake.
@Suite("What a command leaves and reaches", .timeLimit(.minutes(1)))
@MainActor
struct LeftBehindTests {
    private func isExcludedFromBackup(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    @Test func theHistoryFolderIsLeftOutOfBackups() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "ls"])
        let folder = bench.fakes.storage.dataDirectory(for: ShellFeature.featureID)
        #expect(try bench.storedHistory()?.entries.map(\.command) == ["ls"])
        #expect(isExcludedFromBackup(folder))
        #expect(Strings.Settings.historyFooter(appName: "Example").contains("left out of backups"))
    }

    @Test func aHistoryFromBeforeIsLeftOutOfBackupsWhenItIsRead() async throws {
        let bench = Bench()
        try bench.writeHistory(#"{"version": 1, "entries": []}"#)
        let folder = bench.fakes.storage.dataDirectory(for: ShellFeature.featureID)
        #expect(!isExcludedFromBackup(folder))
        await bench.start()
        #expect(isExcludedFromBackup(folder))
    }

    @Test func clearHistoryAlsoDeletesTheCopiesSetAside() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        try bench.writeHistory("{ not json")
        await bench.start()
        let folder = bench.fakes.storage.dataDirectory(for: ShellFeature.featureID)
        let aside = folder.appending(path: "history-damaged-1.json")
        let other = folder.appending(path: "notes.txt")
        try Data("kept".utf8).write(to: other)
        #expect(FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)))
        try await bench.harness.run("run", arguments: ["command": "ls"])

        bench.harness.confirmationAnswer = true
        try await bench.harness.pressSettingsButton("Clear History")
        #expect(bench.feature.history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)), "only its own copies go")
        #expect(bench.harness.confirmations.last?.message?.contains("set aside") == true)
    }

    @Test func theSettingsSayACommandHasTheLaunchersPermissions() {
        let footer = Strings.Settings.runFooter
        #expect(footer.contains("every permission you gave the launcher"))
        #expect(footer.contains("Accessibility") && footer.contains("Full Disk Access"))
        #expect(footer.contains("the camera, the microphone or Bluetooth"))
        #expect(footer.contains("Open in Terminal"))
    }
}
