import Foundation
import Kit
import KitStorage
import KitTesting
import Synchronization
import Testing

@testable import Snippets

@Suite("Text expansion", .timeLimit(.minutes(1)))
struct ExpansionTests {
    private let all = [Fixture.greeting, Fixture.signoff, Fixture.address, Fixture.bug]

    /// A harness with expansion turned on in settings before the feature starts.
    private func expanding(
        _ snippets: [Snippet], fakes: FakeServices = FakeServices(), configure: (FeatureSettings) -> Void = { _ in }
    ) async throws -> FeatureHarness<SnippetsFeature> {
        let settings = fakes.context(featureID: SnippetIDs.feature).settings
        settings[SnippetsSettings.expansionEnabled] = true
        configure(settings)
        return try await FeatureHarness.loaded(snippets, fakes: fakes)
    }

    @Test func expansionIsOffUntilTheUserTurnsItOn() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = try await FeatureHarness.loaded(all, fakes: fakes)
        #expect(await fakes.textExpansion.status() == .stopped)
        #expect(fakes.textExpansion.keywords.isEmpty)
        #expect(harness.feature.status == nil)
        #expect(fakes.permissions.requests.isEmpty)
        // Nothing watches a permission while expansion is off: in the app each watch polls.
        #expect(fakes.permissions.openStreamCount == 0)
        #expect(await fakes.textExpansion.type("sig") == nil)
    }

    @Test func turningItOnInSettingsRegistersKeywordsWithTheirRules() async throws {
        let harness = try await FeatureHarness.loaded(all)
        let settings = harness.context.settings
        settings[SnippetsSettings.expandsWithinWords] = true
        settings[SnippetsSettings.trigger] = .afterDelimiter
        settings[SnippetsSettings.excludedApps] = ["com.example.vault"]
        settings[SnippetsSettings.expansionEnabled] = true
        try await harness.settle()

        let service = harness.fakes.textExpansion
        #expect(await service.status() == .running)
        #expect(service.keywords == ["hi", "sig", "addr"])
        #expect(
            service.options
                == ExpansionOptions(
                    trigger: .afterDelimiter, expandsWithinWords: true, excludedBundleIDs: ["com.example.vault"]))
        #expect(harness.issues.isEmpty)
    }

    @Test func excludedAppsStartWithPasswordManagers() {
        let excluded = SnippetsSettings.excludedApps.defaultValue
        #expect(excluded.contains("com.apple.Passwords"))
        #expect(excluded.contains("com.1password.1password"))
        #expect(SnippetsSettings.expansionEnabled.defaultValue == false)
    }

    @Test func aTypedKeywordBecomesTheRenderedSnippet() async throws {
        let harness = try await expanding(all)
        harness.fakes.pasteboard.simulateCopy("copied words")
        let dated = Fixture.snippet("Dated", #"{date format="yyyy-MM-dd"}: {clipboard}"#, keyword: "dd")
        try await harness.writeFile(all + [dated])
        try await harness.announceFileChange()

        #expect(
            await harness.fakes.textExpansion.type("sig")
                == .insert(Expansion("Best,\n\nThe Team", charactersAfterCursor: 9)))
        #expect(await harness.fakes.textExpansion.type("dd") == .insert(Expansion("2026-11-14: copied words")))
        #expect(harness.fakes.usage.useCount(of: SnippetIDs.row(Fixture.signoff.id)) == 1)
    }

    @Test func aSnippetThatDoesNotExpandIsNotWatched() async throws {
        let quiet = Fixture.snippet("Quiet", "shh", keyword: "qq", expands: false)
        let harness = try await expanding([Fixture.greeting, quiet])
        #expect(harness.fakes.textExpansion.keywords == ["hi"])
        #expect(await harness.fakes.textExpansion.type("qq") == nil)
    }

    @Test func theSharedPrefixIsPartOfEveryKeyword() async throws {
        let harness = try await expanding(all) { $0[SnippetsSettings.keywordPrefix] = " ; " }
        #expect(harness.fakes.textExpansion.keywords == [";hi", ";sig", ";addr"])
        harness.context.settings[SnippetsSettings.keywordPrefix] = "!"
        try await harness.settle()
        #expect(harness.fakes.textExpansion.keywords == ["!hi", "!sig", "!addr"])
        #expect(await harness.fakes.textExpansion.type("!hi") == .insert(Expansion("Hello there")))
    }

    @Test func aSnippetWithArgumentsOpensThePanelToAskForThem() async throws {
        let letter = Fixture.snippet("Letter", #"Dear {argument name="name"},{cursor}"#, keyword: "dear")
        let harness = try await expanding([letter])
        let result = await harness.fakes.textExpansion.type("dear")
        let expected = ExpansionResult.runCommand(
            ItemID.command(feature: "snippets", command: "fill"), arguments: ["snippet": letter.id])
        #expect(result == expected)
        #expect(
            harness.fakes.textExpansion.commandRuns == [
                CommandRun(id: SnippetIDs.fillCommandID, arguments: ["snippet": letter.id])
            ])

        // The host opens the panel on the command, which asks, then pastes back into the same app.
        #expect(try !harness.command("fill").showsInRoot)
        try await harness.run("fill", arguments: ["snippet": letter.id], launch: .textExpansion)
        try harness.fill("name", text: "Sam")
        try await harness.submit()
        #expect(harness.fakes.pasteboard.pastes.map(\.content) == [.text("Dear Sam,")])
        #expect(harness.fakes.pasteboard.pastes.map(\.charactersAfterCursor) == [0])
        #expect(harness.issues.isEmpty)
    }

    @Test func theFillCommandPastesASnippetWhoseArgumentsWereRemoved() async throws {
        let harness = try await expanding([Fixture.greeting])
        try await harness.run("fill", arguments: ["snippet": Fixture.greeting.id], launch: .textExpansion)
        #expect(harness.fakes.pasteboard.pastedTexts == ["Hello there"])
        await #expect(throws: ActionFailure("This Snippet No Longer Exists")) {
            try await harness.run("fill", arguments: ["snippet": "gone"], launch: .textExpansion)
        }
    }

    @Test func keywordChangesReachTheServiceWithoutARestart() async throws {
        let harness = try await expanding([Fixture.greeting])
        let service = harness.fakes.textExpansion
        try await harness.library.add(SnippetDraft(name: "Thanks", text: "Thank you", keyword: "ty"))
        await harness.feature.expansion.update(harness.library.index).value
        #expect(service.keywords == ["hi", "ty"])
        #expect(await service.type("ty") == .insert(Expansion("Thank you")))

        try await harness.library.update(
            id: Fixture.greeting.id, with: SnippetDraft(name: "Greeting", text: "Hey", keyword: "hey"))
        await harness.feature.expansion.update(harness.library.index).value
        #expect(service.keywords == ["hey", "ty"])
        #expect(await service.type("hey") == .insert(Expansion("Hey")))

        try await harness.library.remove(id: Fixture.greeting.id)
        await harness.feature.expansion.update(harness.library.index).value
        #expect(service.keywords == ["ty"])
        #expect(await service.status() == .running)
    }

    @Test func aFileEditedByHandChangesTheKeywords() async throws {
        let harness = try await expanding([Fixture.greeting])
        try await harness.writeFile([Fixture.greeting, Fixture.address])
        try await harness.announceFileChange()
        await harness.feature.expansion.update(harness.library.index).value
        #expect(harness.fakes.textExpansion.keywords == ["hi", "addr"])
    }

    @Test func aMissingPermissionIsReportedWithoutPrompting() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        fakes.textExpansion.missingPermission = .inputMonitoring
        let harness = try await expanding(all, fakes: fakes)
        #expect(harness.feature.expansion.status == .needsPermission(.inputMonitoring))
        #expect(fakes.permissions.openStreamCount == 1, "one watch, for the missing permission")
        let status = try #require(harness.feature.status)
        #expect(status.level == .warning)
        #expect(status.title == "Snippet Expansion Needs Input Monitoring")
        #expect(status.requires == [.inputMonitoring])
        #expect(fakes.permissions.requests.isEmpty)
        #expect(harness.issues.isEmpty)

        // The list says so too, with a button that runs the host's grant flow.
        try await harness.openSearch()
        #expect(harness.page?.notice?.title == "Keywords do not expand until you allow Input Monitoring.")
        #expect(harness.page?.notice?.action?.requires == [.inputMonitoring])

        // Granting it in System Settings starts expansion without a relaunch.
        let declarations = try #require(harness.feature.declarationChanges).generation
        fakes.textExpansion.missingPermission = nil
        fakes.permissions.set(.inputMonitoring, to: .granted)
        try await harness.settle()
        #expect(harness.feature.expansion.status == .running)
        #expect(harness.feature.status == nil)
        #expect(try #require(harness.feature.declarationChanges).generation > declarations)
        #expect(fakes.textExpansion.keywords == ["hi", "sig", "addr"])
        // Running, it watches no permission.
        #expect(fakes.permissions.openStreamCount == 0)
        #expect(harness.page?.notice == nil, "the open list follows without a manual reload")

        // Taken away again while the list is open: the notice comes back at once.
        harness.fakes.textExpansion.simulateStatus(.needsPermission(.accessibility))
        try await harness.settle()
        #expect(harness.page?.notice?.title == "Keywords do not expand until you allow Accessibility.")
    }

    @Test func theListsAllowButtonRunsTheGrantFlowThenStarts() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        fakes.textExpansion.missingPermission = .inputMonitoring
        let harness = try await expanding(all, fakes: fakes)
        try await harness.openSearch()
        let allow = try #require(harness.page?.notice?.action)
        #expect(allow.title == "Allow Input Monitoring")
        await #expect(throws: HarnessError.permissionRequired([.inputMonitoring])) {
            try await harness.perform(allow, row: nil)
        }
        fakes.textExpansion.missingPermission = nil
        harness.grantsMissingPermissions = true
        try await harness.perform(allow, row: nil)
        #expect(fakes.permissions.requests.contains(.inputMonitoring))
        #expect(harness.feature.expansion.status == .running)
        #expect(harness.page?.notice == nil)
    }

    @Test func secureInputPausesAndResumes() async throws {
        let harness = try await expanding(all)
        let declarations = try #require(harness.feature.declarationChanges).generation
        harness.fakes.textExpansion.simulateStatus(.blockedBySecureInput(owner: "Example Vault"))
        try await harness.settle()
        #expect(harness.feature.status?.level == .info)
        #expect(harness.feature.status?.title == "Snippet Expansion Is Paused While Example Vault Has Secure Input On")
        #expect(try #require(harness.feature.declarationChanges).generation == declarations + 1)

        harness.fakes.textExpansion.simulateStatus(.blockedBySecureInput(owner: nil))
        try await harness.settle()
        #expect(harness.feature.status?.title == "Snippet Expansion Is Paused While Another App Has Secure Input On")

        harness.fakes.textExpansion.simulateStatus(.running)
        try await harness.settle()
        #expect(harness.feature.status == nil)
    }

    @Test func aPermissionTakenAwayWhileRunningShowsInStatus() async throws {
        let harness = try await expanding(all)
        harness.fakes.textExpansion.simulateStatus(.needsPermission(.accessibility))
        try await harness.settle()
        #expect(harness.feature.status?.requires == [.accessibility])
    }

    @Test func turnOnAndTurnOffCommands() async throws {
        let harness = try await FeatureHarness.loaded(all)
        #expect(try harness.command("turn-on-expansion").requires == [.inputMonitoring, .accessibility])
        try await harness.run("turn-on-expansion")
        #expect(harness.huds.last == "Snippet Expansion Is On")
        #expect(harness.context.settings[SnippetsSettings.expansionEnabled])
        #expect(await harness.fakes.textExpansion.status() == .running)

        try await harness.run("turn-off-expansion")
        #expect(harness.huds.last == "Snippet Expansion Is Off")
        #expect(await harness.fakes.textExpansion.status() == .stopped)
        #expect(await harness.fakes.textExpansion.type("sig") == nil)
    }

    @Test func rootSearchShowsOnlyTheSwitchThatApplies() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = try await FeatureHarness.loaded(all, fakes: fakes)
        func shown() throws -> [String] {
            try ["turn-on-expansion", "turn-off-expansion"].filter { try harness.command($0).showsInRoot }
        }
        #expect(try shown() == ["turn-on-expansion"])
        #expect(try harness.command("turn-off-expansion").allowsDeepLinks == false)

        // Turned on in settings: root search reads the commands again and shows Turn Off.
        let declarations = try #require(harness.feature.declarationChanges).generation
        harness.context.settings[SnippetsSettings.expansionEnabled] = true
        try await harness.settle()
        #expect(try #require(harness.feature.declarationChanges).generation > declarations)
        #expect(try shown() == ["turn-off-expansion"])
        #expect(try harness.command("turn-on-expansion").allowsDeepLinks == false)

        // Still on while it waits for a permission, so Turn Off stays.
        fakes.textExpansion.simulateStatus(.needsPermission(.inputMonitoring))
        try await harness.settle()
        #expect(try shown() == ["turn-off-expansion"])

        // Both stay declared, so a hotkey on the hidden one still runs.
        try await harness.run("turn-off-expansion")
        #expect(try shown() == ["turn-on-expansion"])
        try await harness.run("turn-off-expansion")
        #expect(harness.huds.last == "Snippet Expansion Is Off")
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func turningTheSettingOffStops() async throws {
        let harness = try await expanding(all)
        harness.context.settings[SnippetsSettings.expansionEnabled] = false
        try await harness.settle()
        #expect(await harness.fakes.textExpansion.status() == .stopped)
        #expect(harness.feature.status == nil)
    }

    @Test func deactivatingStops() async throws {
        let harness = try await expanding(all)
        await harness.deactivate()
        #expect(await harness.fakes.textExpansion.status() == .stopped)
    }

    @Test func keywordWorkHappensOffTheMainThread() async throws {
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.expansionEnabled] = true
        let spy = ThreadRecordingExpansion()
        var services = fakes.services
        services.textExpansion = spy
        let context = FeatureContext(featureID: SnippetIDs.feature, environment: .selftest, services: services)
        let feature = SnippetsFeature(context: context)
        try await JSONFileStore<SnippetFile>(url: feature.library.fileURL).save(
            SnippetFile(snippets: [Fixture.greeting]))
        await feature.activate()
        await feature.ready()
        try await feature.library.add(SnippetDraft(name: "Thanks", text: "Thank you", keyword: "ty"))
        await feature.expansion.update(feature.library.index).value

        #expect(spy.calls.map(\.name).contains("start"))
        #expect(spy.calls.map(\.name).contains("updateKeywords"))
        #expect(spy.calls.allSatisfy { !$0.onMainThread }, "\(spy.calls)")
        #expect(spy.lastKeywords == ["hi", "ty"])
        let expansion = await spy.expand("ty")
        #expect(expansion == .insert(Expansion("Thank you")))
        await feature.deactivate()
    }
}

/// Records which thread each call arrives on.
nonisolated final class ThreadRecordingExpansion: TextExpansionService {
    struct Call: Sendable, CustomStringConvertible {
        var name: String
        var onMainThread: Bool
        var description: String { "\(name) main=\(onMainThread)" }
    }

    private struct State {
        var calls: [Call] = []
        var keywords: Set<String> = []
        var handler: (@Sendable (String) async -> ExpansionResult)?
    }

    private let state = Mutex(State())

    init() {}

    var calls: [Call] { state.withLock { $0.calls } }
    var lastKeywords: Set<String> { state.withLock { $0.keywords } }

    func expand(_ keyword: String) async -> ExpansionResult? {
        guard let handler = state.withLock({ $0.handler }) else { return nil }
        return await handler(keyword)
    }

    private func record(_ name: String) {
        let onMain = pthread_main_np() != 0
        state.withLock { $0.calls.append(Call(name: name, onMainThread: onMain)) }
    }

    func start(
        keywords: Set<String>, options: ExpansionOptions, expand: @escaping @Sendable (String) async -> ExpansionResult
    ) async -> TextExpansionStatus {
        record("start")
        state.withLock {
            $0.keywords = keywords
            $0.handler = expand
        }
        return .running
    }

    func updateKeywords(_ keywords: Set<String>) async {
        record("updateKeywords")
        state.withLock { $0.keywords = keywords }
    }

    func stop() async {
        record("stop")
    }

    func status() async -> TextExpansionStatus { .running }

    func statusChanges() -> AsyncStream<TextExpansionStatus> {
        AsyncStream { _ in }
    }
}
