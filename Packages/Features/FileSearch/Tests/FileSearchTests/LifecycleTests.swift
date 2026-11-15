import Foundation
import Kit
import KitTesting
import Testing

@testable import FileSearch

@Suite("Lifecycle, commands and settings", .timeLimit(.minutes(1)))
@MainActor
struct LifecycleTests {
    @Test func theManifestDeclaresEveryPermissionWithAReason() {
        let manifest = FileSearchFeature.manifest
        #expect(manifest.id == "files")
        #expect(
            Set(manifest.permissions.map(\.permission)) == [
                .protectedFolder(.desktop), .protectedFolder(.documents), .protectedFolder(.downloads),
                .protectedFolder(.removableVolumes), .protectedFolder(.networkVolumes), .fullDiskAccess,
            ])
        for need in manifest.permissions {
            #expect(need.reason.hasPrefix("Search"), "\(need.reason)")
            #expect(need.reason.hasSuffix("."))
        }
    }

    @Test func outsideTheAppTheIndexIsSyntheticAndNothingIsRead() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = FeatureHarness(FileSearchFeature.self, fakes: fakes)
        #expect(harness.context.environment != .live)
        #expect(harness.feature.fileSystem is SimulatedFileSystem)
        await harness.activate()
        await harness.feature.waitUntilIdle()
        #expect(harness.feature.controller.summary.count >= SyntheticIndexMaker.scenarioEntries)
        let rows = try await harness.asyncSections(for: "report").flatMap(\.rows)
        #expect(!rows.isEmpty)
        let home = fakes.storage.homeDirectory.path(percentEncoded: false)
        #expect(rows.allSatisfy { $0.id.key.hasPrefix(home.trimmingSuffix("/")) })
        #expect(!FileManager.default.fileExists(atPath: harness.feature.controller.file), "nothing is written")
        #expect(fakes.permissions.requests.isEmpty)
        await harness.deactivate()
    }

    @Test func activatingTwiceKeepsOneWatchAndStoppingEndsEverything() async throws {
        let fixture = try Fixture()
        fixture.fakes.permissions.answer = .denied
        try await fixture.start()
        await fixture.harness.activate()
        try await fixture.idle()
        #expect(fixture.fakes.fileWatcher.watchedDirectories.count == 1)
        #expect(fixture.maker.opens == 1, "the open index is kept")
        try await fixture.harness.pressSettingsButton("Search Downloads Folder")
        try await fixture.idle()
        #expect(fixture.fakes.permissions.openStreamCount == 1)
        await fixture.harness.deactivate()
        #expect(fixture.fakes.fileWatcher.watchedDirectories.isEmpty)
        #expect(fixture.fakes.permissions.openStreamCount == 0)
        #expect(fixture.feature.controller.summary.phase == .idle)
        // Back on: the saved file opens and the choice is remembered.
        await fixture.harness.activate()
        try await fixture.idle()
        #expect(fixture.feature.placeStates()[.downloads] == .waitingForAccess)
        #expect(fixture.fakes.permissions.openStreamCount == 1)
        #expect(try await fixture.rootPaths("notes") == ["notes.md"])
        await fixture.harness.deactivate()
    }

    @Test func rebuildWalksAgainAndReportsTheCount() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        try fixture.tree.write("unseen.txt")
        try await fixture.harness.run("rebuild")
        #expect(fixture.harness.toasts.map(\.title) == ["Rebuilding File Index", "File Index Rebuilt"])
        let count = fixture.feature.controller.summary.count
        #expect(fixture.harness.toasts.last?.message == "The index holds \(count) items.")
        #expect(fixture.maker.rebuilds == 1)
        #expect(try await fixture.rootPaths("unseen") == ["unseen.txt"])
        let command = try fixture.harness.command("rebuild")
        #expect(command.runPolicy == .dropWhileRunning)
        #expect(await command.liveSubtitle?.value()?.text == "\(count) items, updated just now")
        fixture.fakes.clock.advance(by: .seconds(600))
        let later = await command.liveSubtitle?.value()?.text
        #expect(later == "\(count) items, updated 10 minutes ago")
    }

    @Test func theSettingsPaneSaysWhatIsStoredAndOffersEachPlace() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let pane = try #require(fixture.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        let titles = items.map(\.title)
        for place in ProtectedPlace.allCases {
            #expect(titles.contains(Strings.Places.search(place)), "\(place)")
        }
        #expect(titles.contains("Search All Protected Folders"))
        #expect(titles.contains("Full Disk Access"))
        #expect(titles.contains("Rebuild File Index"))
        #expect(titles.contains { $0.hasPrefix("The index holds") })
        let storage = try #require(titles.first { $0.hasPrefix("The index keeps only") })
        #expect(storage.contains("data/files") && storage.contains("sends nothing over the network"))
        #expect(pane.sections.map(\.title) == ["Root Search", "Protected Places", "Folders and Names", "Index"])
        try await fixture.harness.pressSettingsButton("Rebuild File Index")
        #expect(fixture.harness.toasts.map(\.title) == ["File Index Rebuilt"])
    }

    @Test func titlesFollowTheHouseStyle() {
        let titles =
            [
                Strings.Commands.search, Strings.Commands.rebuild, Strings.Commands.chooseFolders, Strings.Root.section,
                Strings.Actions.copyFile, Strings.Actions.copiedFile, Strings.Actions.copyName, Strings.Index.rebuilt,
                Strings.Index.rebuilding, Strings.Index.rebuildFailed, Strings.Page.recentSection,
                Strings.Places.searchAll,
                Strings.Status.failed, Strings.Status.building, Strings.Status.damaged,
                Strings.Page.buildingState.title, Strings.Page.noMatchesState.title, Strings.Page.noRecentsState.title,
                Strings.Page.notIndexedState.title, Strings.Page.failedState.title,
            ] + ProtectedPlace.allCases.flatMap { [Strings.Places.search($0), Strings.Places.stop($0)] }
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            #expect(title.first?.isUppercase == true, "\(title)")
        }
        let sentences = [
            Strings.summary, Strings.Page.notSearchedMessage, Strings.Settings.showsInRootInfo,
            Strings.Settings.placesFooter, Strings.Settings.excludedNamesInfo,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
            #expect(!sentence.contains("\u{2014}"), "\(sentence)")
        }
    }
}
