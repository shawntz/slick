import Foundation
import Kit
import KitTesting
import Testing

@testable import People

@Suite("Access", .timeLimit(.minutes(1)))
@MainActor
struct AccessTests {
    @Test func activationReadsNothingAndAsksNothing() async throws {
        let (harness, store) = await makeHarness(access: .granted)
        try await harness.settle()
        #expect(store.peopleReads == 0)
        #expect(store.photoReads == 0)
        #expect(store.listenerCount == 0)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func withAccessMissingNothingReadsAndNothingPrompts() async throws {
        let (harness, store) = await makeHarness(access: .notDetermined)
        #expect(try await harness.catalogRows().isEmpty)
        await #expect(throws: HarnessError.self) { try await harness.run("search") }
        #expect(store.peopleReads == 0)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
    }

    @Test func runningSearchContactsAsksThroughTheHostThenLists() async throws {
        let (harness, store) = await makeHarness(access: .notDetermined)
        #expect(try await harness.catalogRows().isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.run("search")
        #expect(harness.fakes.permissions.requests == [.contacts])
        #expect(harness.titles.count == Cast.all.count)
        #expect(store.peopleReads == 1)
        #expect(store.listenerCount == 1)
        // Root search heard that people arrived, and now finds them.
        #expect(harness.feature.directory.changes.generation > 0)
        #expect(try await harness.catalogRows().count == Cast.all.count)
        #expect(store.peopleReads == 1)
    }

    @Test func aRefusedPromptLeavesEverythingEmpty() async throws {
        let (harness, store) = await makeHarness(access: .notDetermined)
        harness.grantsMissingPermissions = true
        harness.fakes.permissions.answer = .denied
        await #expect(throws: HarnessError.self) { try await harness.run("search") }
        #expect(store.peopleReads == 0)
        #expect(try await harness.catalogRows().isEmpty)
    }

    @Test func accessTakenAwayEmptiesTheListAndRootSearch() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        #expect(try await harness.catalogRows().count == Cast.all.count)
        try harness.select(personID(Cast.ana))
        #expect(harness.actions().count > 2)

        harness.fakes.permissions.set(.contacts, to: .denied)
        store.isReadable = false
        store.save(Person(id: "p-new", givenName: "Nadia"))
        try await harness.waitForChange()

        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == Strings.Access.offTitle)
        #expect(harness.feature.directory.snapshot == nil)
        #expect(!harness.feature.directory.isFollowing)
        #expect(try await harness.catalogRows().isEmpty)
        #expect(
            harness.rootActions(for: Row(id: personID(Cast.ana), title: "Ana Lima")).map(\.id) == ["open-in-contacts"])
        #expect(harness.fakes.permissions.requests.isEmpty)
    }

    @Test func accessFoundMissingHoldsNoStreamAndAGrantInSettingsReloads() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        harness.fakes.permissions.set(.contacts, to: .denied)
        try await harness.reloadPage()
        #expect(harness.page?.emptyState?.title == Strings.Access.offTitle)
        #expect(harness.fakes.permissions.openStreamCount == 0, "no stream waits for the grant")

        try await harness.grantInSettings(.contacts)
        #expect(harness.titles.count == Cast.all.count)
        #expect(store.peopleReads == 2)
    }

    @Test func aGrantInSettingsOrOnboardingFillsRootSearch() async throws {
        let (harness, store) = await makeHarness(access: .notDetermined)
        #expect(try await harness.catalogRows().isEmpty)
        let before = harness.feature.directory.changes.generation
        try await harness.grantInSettings(.contacts)
        #expect(harness.feature.directory.changes.generation > before, "root search asks the catalog again")
        #expect(try await harness.catalogRows().count == Cast.all.count)
        #expect(store.peopleReads == 1)
        #expect(harness.fakes.permissions.openStreamCount == 0)
    }

    @Test func theAllowButtonOnTheListAsksThroughTheHost() async throws {
        let (harness, _) = await makeHarness()
        try await harness.run("search")
        harness.fakes.permissions.set(.contacts, to: .notDetermined)
        try await harness.reloadPage()
        let allow = try #require(harness.page?.emptyState?.actions.first)
        #expect(allow.requires == [.contacts])
        harness.grantsMissingPermissions = true
        try await harness.perform(allow, row: nil)
        #expect(harness.fakes.permissions.requests == [.contacts])
        #expect(harness.titles.count == Cast.all.count)
    }

    @Test func theSettingsButtonAsksAndRootSearchFillsAfterAGrant() async throws {
        let (harness, store) = await makeHarness(access: .notDetermined)
        #expect(try await harness.catalogRows().isEmpty)
        try await harness.pressSettingsButton(Strings.Settings.allowAccess)
        #expect(harness.fakes.permissions.requests == [.contacts])
        #expect(harness.toasts.last?.title == Strings.Access.onTitle)
        #expect(harness.feature.directory.changes.generation > 0)
        #expect(try await harness.catalogRows().count == Cast.all.count)
        #expect(store.peopleReads == 1)
    }

    @Test func aRefusalInSettingsSaysHowToTurnItOnAndHoldsNoStream() async throws {
        let (harness, _) = await makeHarness(access: .notDetermined)
        harness.fakes.permissions.answer = .denied
        try await harness.pressSettingsButton(Strings.Settings.allowAccess)
        #expect(harness.toasts.last?.title == Strings.Access.offTitle)
        #expect(harness.toasts.last?.message?.hasSuffix("and open Search Contacts again.") == true)
        #expect(harness.fakes.permissions.openStreamCount == 0)

        // Turned on later in System Settings: the next read finds access.
        harness.fakes.permissions.set(.contacts, to: .granted)
        #expect(try await harness.catalogRows().count == Cast.all.count)
    }

    @Test func turningTheFeatureOffForgetsEveryone() async throws {
        let (harness, store) = await makeHarness()
        try await harness.run("search")
        #expect(store.listenerCount == 1)
        await harness.deactivate()
        #expect(harness.feature.directory.snapshot == nil)
        await waitUntil { store.listenerCount == 0 }
        #expect(store.listenerCount == 0)

        // A grant while the feature is off reads nothing.
        let generation = harness.feature.directory.changes.generation
        await harness.feature.permissionGranted(.contacts)
        #expect(harness.feature.directory.changes.generation == generation)
        #expect(harness.feature.directory.snapshot == nil)
    }

    @Test func aRestrictedMacSaysWhy() async throws {
        let (harness, _) = await makeHarness(access: .notDetermined)
        harness.fakes.permissions.answer = .restricted
        try await harness.pressSettingsButton(Strings.Settings.allowAccess)
        #expect(harness.toasts.last?.message == Strings.Access.restrictedMessage)
        #expect(harness.fakes.permissions.openStreamCount == 0)
    }
}

/// Yields until the condition holds, for state a background task changes. Gives up after many
/// yields, so a failing test ends with a failed expectation rather than the time limit.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10_000 where !condition() {
        await Task.yield()
    }
}
