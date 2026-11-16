import Foundation
import Kit
import Testing

@testable import SlickApp

/// Made-up files and the open dialogs a scenario plays: files go only inside the run's home folder,
/// and each open dialog hands back what a step queued, then cancels.
@Suite("Scenario files and dialogs", .timeLimit(.minutes(1)))
struct ScenarioFileStepTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "scenario-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test(arguments: [
        "", "/etc/hosts", "~/notes.txt", "../outside.txt", "docs/../../outside.txt", "./notes.txt", "a//b",
    ])
    func aPathThatLeavesTheHomeFolderIsRefused(path: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ScenarioHomeFiles.resolve(path, in: home) == nil)
        #expect(ScenarioHomeFiles.write([path: "text"], in: home).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func filesAreWrittenInsideTheHomeFolderAndNeverOverwritten() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ScenarioHomeFiles.write(["docs/plan.rs": "first"], in: home).isEmpty)
        let file = try #require(ScenarioHomeFiles.resolve("docs/plan.rs", in: home))
        #expect(file.path.hasPrefix(home.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "first")
        #expect(ScenarioHomeFiles.write(["docs/plan.rs": "second"], in: home).count == 1, "a file is never replaced")
        #expect(try String(contentsOf: file, encoding: .utf8) == "first")
    }

    @Test func eachOpenDialogTakesTheNextQueuedAnswerThenCancels() async {
        let dialogs = ScenarioFileDialogs()
        let first = [URL(filePath: "/tmp/example/one.json")]
        let second = [URL(filePath: "/tmp/example/two.json"), URL(filePath: "/tmp/example/three.json")]
        dialogs.queue(first)
        dialogs.queue(second)
        #expect(await dialogs.chooseFiles(OpenDialogRequest(title: "One")) == first)
        #expect(await dialogs.chooseFiles(OpenDialogRequest(title: "Two", allowsMultiple: true)) == second)
        #expect(await dialogs.chooseFiles(OpenDialogRequest(title: "Three")).isEmpty, "nothing queued cancels")
        #expect(dialogs.openRequests.map(\.title) == ["One", "Two", "Three"])
        #expect(await dialogs.chooseSaveLocation(SaveDialogRequest(suggestedName: "export.json")) == nil)
        #expect(dialogs.saveRequests.map(\.suggestedName) == ["export.json"])
    }

    @Test func theStepsReadTheirKeys() throws {
        let json = #"""
            {"makeFiles": {"Imports/list.json": "[]"}, "chooseFiles": ["Imports/list.json"],
             "homeFiles": ["Imports/list.json"], "openDialogs": 1}
            """#
        let step = try JSONDecoder().decode(AppStep.self, from: Data(json.utf8))
        #expect(step.makeFiles == ["Imports/list.json": "[]"])
        #expect(step.chooseFiles == ["Imports/list.json"])
        #expect(step.homeFiles == ["Imports/list.json"])
        #expect(step.openDialogs == 1)
    }
}
