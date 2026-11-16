import Foundation
import Kit
import KitTesting
import Testing

@testable import ShellCommands

@Suite("Open in Terminal", .timeLimit(.minutes(1)))
@MainActor
struct TerminalTests {
    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func folder(_ bench: Bench) -> URL {
        bench.fakes.storage.cacheDirectory(for: ShellFeature.featureID).appending(
            path: TerminalScript.folderName, directoryHint: .isDirectory)
    }

    @Test func aScriptOnlyTheUserCanReadAndRunOpensWithTerminal() async throws {
        let bench = Bench()
        await bench.start()
        bench.feature.context.settings[ShellSettings.workingFolder] = "~/it's here"
        let row = try #require(try await bench.rootRow("> sudo port selfupdate"))
        let outcome = try await bench.harness.performRoot("open-in-terminal", on: row)
        #expect(
            outcome.kind
                == .run(ShellFeature.terminalCommandID, arguments: outcomeArguments(bench, "sudo port selfupdate")))
        #expect(bench.harness.isClosed, "Terminal comes forward")

        let opened = try #require(bench.fakes.workspace.openedWith.first)
        #expect(opened.bundleID == "com.apple.Terminal")
        let script = try #require(opened.urls.first)
        #expect(
            script.deletingLastPathComponent().path(percentEncoded: false) == folder(bench).path(percentEncoded: false))
        #expect(script.lastPathComponent.hasPrefix("run-") && script.pathExtension == "command")
        #expect(try permissions(script) == 0o700)
        #expect(try permissions(folder(bench)) == 0o700)
        let text = try String(contentsOf: script, encoding: .utf8)
        let home = bench.home.path(percentEncoded: false)
        let path = script.path(percentEncoded: false)
        #expect(
            text
                == "#!/bin/zsh -l\n/bin/rm -f -- '\(path)'\ncd '\(home)it'\\''s here/' || exit 1\nsudo port selfupdate\n"
        )
        #expect(bench.fakes.processes.runs.isEmpty, "nothing runs here")
        #expect(try bench.storedHistory() == nil)
    }

    private func outcomeArguments(_ bench: Bench, _ text: String) -> [String: String] {
        bench.feature.handOff.arguments(for: text)
    }

    @Test func thePageOffersOpenInTerminalForACommandThatWantsInput() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stderr("Password: sudo: no tty present\n", exitCode: 1))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "sudo ls"])
        let detail = try #require(bench.harness.detail)
        #expect(detail.metadata.last == .label("Input", value: Strings.Page.inputNote))
        #expect(detail.metadata.dropLast().last == .separator)
        try await bench.harness.perform("open-in-terminal")
        #expect(bench.fakes.workspace.openedWith.count == 1)
    }

    @Test func pathsAreQuotedForTheShell() {
        #expect(TerminalScript.quoted("/Users/a/b c") == "'/Users/a/b c'")
        #expect(TerminalScript.quoted("/tmp/it's") == "'/tmp/it'\\''s'")
        #expect(TerminalScript.quoted("/tmp/$(rm -rf x)`y`") == "'/tmp/$(rm -rf x)`y`'")
    }

    @Test func aShellPathThatCannotGoOnAFirstLineIsRefused() throws {
        let command = try ShellCommand.check("ls").get()
        let folder = URL(filePath: "/tmp/", directoryHint: .isDirectory)
        let script = URL(filePath: "/tmp/run-1.command")
        #expect(throws: TerminalScript.Problem.shellPath) {
            try TerminalScript.text(command: command, shell: "/opt/my shells/fish", folder: folder, script: script)
        }
        #expect(throws: TerminalScript.Problem.shellPath) {
            try TerminalScript.text(command: command, shell: "fish", folder: folder, script: script)
        }
        #expect(
            try TerminalScript.text(command: command, shell: "/opt/homebrew/bin/fish", folder: folder, script: script)
                == "#!/opt/homebrew/bin/fish -l\n/bin/rm -f -- '/tmp/run-1.command'\ncd '/tmp/' || exit 1\nls\n")
        // csh and tcsh take -l only as their one flag, and a script's path follows it.
        for shell in ["/bin/tcsh", "/bin/csh"] {
            #expect(
                try TerminalScript.text(command: command, shell: shell, folder: folder, script: script)
                    .hasPrefix("#!\(shell)\n/bin/rm -f -- "))
        }
    }

    @Test func oldScriptsAreDeletedAndRecentOnesKept() async throws {
        let storage = FakeStorage()
        let folder = storage.cacheDirectory(for: "shell").appending(path: "Terminal", directoryHint: .isDirectory)
        let first = try await TerminalScript.write("echo 1\n", in: folder)
        let second = try await TerminalScript.write("echo 2\n", in: folder)
        let manager = FileManager.default
        let hourAgo = Date(timeIntervalSinceNow: -3600)
        try manager.setAttributes([.modificationDate: hourAgo], ofItemAtPath: first.path(percentEncoded: false))
        let other = folder.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: other)
        try manager.setAttributes([.modificationDate: hourAgo], ofItemAtPath: other.path(percentEncoded: false))
        let link = folder.appending(path: "run-link.command")
        try manager.createSymbolicLink(at: link, withDestinationURL: other)

        let third = try await TerminalScript.write("echo 3\n", in: folder)
        #expect(
            !manager.fileExists(atPath: first.path(percentEncoded: false)), "an hour old: Terminal read it long ago")
        #expect(manager.fileExists(atPath: second.path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: third.path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: other.path(percentEncoded: false)), "only the feature's scripts go")
        #expect((try? manager.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))) != nil)
    }

    @Test func aLinkInPlaceOfTheFolderIsRefused() async throws {
        let storage = FakeStorage()
        let cache = storage.cacheDirectory(for: "shell")
        let elsewhere = storage.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let folder = cache.appending(path: "Terminal", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(
            at: cache.appending(path: "Terminal"), withDestinationURL: elsewhere)
        await #expect(throws: TerminalScript.Problem.self) {
            _ = try await TerminalScript.write("echo hi\n", in: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path(percentEncoded: false)).isEmpty)
    }

    @Test func aFailedWriteSaysWhy() async throws {
        let bench = Bench()
        await bench.start()
        let cache = bench.fakes.storage.cacheDirectory(for: ShellFeature.featureID)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: cache.appending(path: TerminalScript.folderName))
        bench.harness.throwsActionErrors = false
        try await bench.harness.run(
            "open-in-terminal", arguments: bench.feature.handOff.arguments(for: "top"), launch: .command)
        #expect(bench.harness.toasts.last?.title == "Could Not Open in Terminal")
        #expect(bench.fakes.workspace.openedWith.isEmpty)
    }

    @Test func historyRowsNeverOpenTerminal() async throws {
        let bench = Bench()
        bench.fakes.processes.stub("/bin/zsh", output: .stdout(""))
        await bench.start()
        try await bench.harness.run("run", arguments: ["command": "make"])
        try await bench.harness.run("history")
        #expect(!bench.harness.actions().map(\.id).contains("open-in-terminal"))
    }
}
