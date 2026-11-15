import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("File events and saving", .timeLimit(.minutes(1)))
@MainActor
struct EventTests {
    @Test func aBatchOfEventsIsAppliedInOneCall() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try fixture.tree.write("Projects/app/src/parser.swift")
        try fixture.tree.write("Projects/agenda.txt")
        fixture.fakes.fileWatcher.simulateChange([
            fixture.tree.url("Projects/app/src/parser.swift"), fixture.tree.url("Projects/agenda.txt"),
            fixture.tree.url("Projects/agenda.txt"),
        ])
        try await fixture.idle()
        #expect(fixture.maker.batches.count == 1)
        #expect(
            fixture.appliedPaths == ["Projects/app/src/parser.swift", "Projects/agenda.txt"], "repeats are dropped")
        #expect(fixture.maker.batches.first?.allSatisfy { $0.flags == 0 } == true)
        #expect(try await fixture.rootPaths("parser") == ["Projects/app/src/parser.swift"])
        #expect(try await fixture.rootPaths("agenda") == ["Projects/agenda.txt"])
        try fixture.tree.remove("Projects/agenda.txt")
        // The event names the folder: Kit's fake watcher cannot match a deleted file below /private.
        fixture.fakes.fileWatcher.simulateChange([fixture.tree.url("Projects")])
        try await fixture.idle()
        #expect(try await fixture.rootPaths("agenda").isEmpty)
        #expect(fixture.feature.controller.summary.count > 0)
    }

    @Test func eventsBelowFoldersOutsideTheScopeNeverReachTheIndex() async throws {
        let fixture = try Fixture { $0[FileSearchSettings.excludedFolders] = ["~/Archive"] }
        try await fixture.start()
        try fixture.tree.write("Desktop/new-shot.png")
        try fixture.tree.write("Archive/new-archive.zip")
        fixture.fakes.fileWatcher.simulateChange([
            fixture.tree.url("Desktop/new-shot.png"), fixture.tree.url("Archive/new-archive.zip"),
            fixture.tree.url("Desktop"),
        ])
        try await fixture.idle()
        #expect(fixture.maker.batches.isEmpty)
        #expect(try await fixture.rootPaths("new-shot").isEmpty)
        #expect(try await fixture.rootPaths("old-photos").isEmpty, "the excluded folder was never walked")
    }

    @Test func anEventForARootRescansTheWholeSubtree() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        // Changes FSEvents never reported one by one, as after it dropped events.
        try fixture.tree.write("Projects/app/src/deep/missed.swift")
        try fixture.tree.write("Music/album/missed-track.mp3")
        // A change next to them lists only its own folder.
        fixture.fakes.fileWatcher.simulateChange([fixture.tree.url("notes.md")])
        try await fixture.idle()
        #expect(try await fixture.rootPaths("missed").isEmpty)
        // FSEvents names the root itself when it could not say what changed below it.
        fixture.fakes.fileWatcher.simulateChange([URL(filePath: fixture.tree.home, directoryHint: .isDirectory)])
        try await fixture.idle()
        #expect(fixture.maker.batches.last?.map(\.flags) == [IndexController.mustScanSubDirs])
        #expect(
            Set(try await fixture.rootPaths("missed")) == [
                "Projects/app/src/deep/missed.swift", "Music/album/missed-track.mp3",
            ])
    }

    @Test func theIndexIsSavedAtAQuietMomentAndWhenTheFeatureStops() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let savedAfterOpen = fixture.maker.saves
        #expect(savedAfterOpen == 1, "a new walk is saved at once")
        try fixture.tree.write("quiet.txt")
        fixture.fakes.fileWatcher.simulateChange([fixture.tree.url("quiet.txt")])
        try await fixture.idle()
        #expect(fixture.maker.saves == savedAfterOpen, "nothing is written while changes may still come")
        await fixture.fakes.clock.waitForSleepers()
        fixture.fakes.clock.advance(by: IndexController.quietPeriod + .seconds(1))
        await fixture.feature.controller.waitForScheduledSave()
        #expect(fixture.maker.saves == savedAfterOpen + 1)
        #expect(try savedPaths(fixture, matching: "quiet") == ["quiet.txt"])

        try fixture.tree.write("closing.txt")
        fixture.fakes.fileWatcher.simulateChange([fixture.tree.url("closing.txt")])
        try await fixture.idle()
        await fixture.harness.deactivate()
        #expect(try savedPaths(fixture, matching: "closing") == ["closing.txt"])
        #expect(fixture.feature.controller.index == nil, "the index is let go while the feature is off")
        #expect(fixture.fakes.fileWatcher.watchedDirectories.isEmpty)
    }

    @Test func aSavedIndexOpensFromItsFileAndCatchesUpOnWhatChangedMeanwhile() async throws {
        let tree = try TestTree()
        let first = try Fixture(tree: tree)
        try await first.start()
        await first.harness.deactivate()
        try tree.write("while-off.txt")

        let second = try Fixture(tree: tree)
        try await second.start()
        #expect(second.maker.opens == 1 && second.maker.builds == 0, "the saved file was used")
        #expect(second.maker.rebuilds == 1, "then everything was walked once to catch up")
        #expect(try await second.rootPaths("while-off") == ["while-off.txt"])
        withExtendedLifetime(first) {}
    }

    @Test func aDamagedIndexFileIsBuiltAgain() async throws {
        let tree = try TestTree()
        try FileManager.default.createDirectory(
            atPath: Paths.parent(of: tree.indexFile), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 4_096).write(to: URL(filePath: tree.indexFile))
        let fixture = try Fixture(tree: tree)
        try await fixture.start()
        #expect(fixture.feature.controller.summary.rebuiltAfterDamage)
        #expect(fixture.feature.status?.title == "File Index Rebuilt")
        #expect(fixture.feature.status?.level == .info)
        #expect(try await fixture.rootPaths("notes") == ["notes.md"])
        // The damaged file was replaced by a good one.
        let (_, opening) = try DiskIndexMaker().open(at: tree.indexFile, fixture.feature.controller.plan!.configuration)
        #expect(opening.fromFile && opening.loadError == nil)
        // A rebuild clears the notice.
        try await fixture.harness.run("rebuild")
        #expect(fixture.feature.status == nil)
    }

    @Test func aTruncatedIndexFileIsBuiltAgain() async throws {
        let tree = try TestTree()
        let first = try Fixture(tree: tree)
        try await first.start()
        await first.harness.deactivate()
        let data = try Data(contentsOf: URL(filePath: tree.indexFile))
        try data.prefix(data.count / 2).write(to: URL(filePath: tree.indexFile))
        let second = try Fixture(tree: tree)
        try await second.start()
        #expect(second.feature.controller.summary.rebuiltAfterDamage)
        #expect(try await second.rootPaths("notes") == ["notes.md"])
        withExtendedLifetime(first) {}
    }

    /// The paths of the saved index file that match a query, relative to home.
    private func savedPaths(_ fixture: Fixture, matching query: String) throws -> [String] {
        let plan = fixture.feature.controller.plan ?? lastPlan(fixture)
        let (index, opening) = try DiskIndexMaker().open(at: fixture.tree.indexFile, plan.configuration)
        #expect(opening.fromFile)
        let session = try FileSearchSession()
        let count = try session.search(query, in: index)
        return (0..<count).compactMap { session.path(of: session[$0].id) }.map(fixture.relative)
    }

    private func lastPlan(_ fixture: Fixture) -> ScopePlan {
        ScopePlan(
            ScopeInput(
                home: fixture.tree.home,
                states: Dictionary(uniqueKeysWithValues: ProtectedPlace.allCases.map { ($0, .notSearched) })))
    }
}
