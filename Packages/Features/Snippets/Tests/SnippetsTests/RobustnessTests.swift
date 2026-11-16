import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import Snippets

/// Odd and hostile input: the feature switched off and on, files from a newer version, imported
/// keywords that would misfire, Unicode keywords, foreign root queries and an empty library.
@Suite("Odd and hostile input", .timeLimit(.minutes(1)))
struct RobustnessTests {
    // MARK: Switching off and on

    @Test func switchingTheFeatureBackOnReadsEditsMadeWhileItWasOff() async throws {
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.expansionEnabled] = true
        let harness = try await FeatureHarness.loaded([Fixture.greeting], fakes: fakes)
        #expect(fakes.textExpansion.keywords == ["hi"])

        await harness.deactivate()
        #expect(await fakes.textExpansion.status() == .stopped)
        try await harness.writeFile([Fixture.greeting, Fixture.signoff])
        await harness.start()

        #expect(harness.library.index.snippets.map(\.name) == ["Greeting", "Sign Off"])
        #expect(await fakes.textExpansion.status() == .running)
        #expect(fakes.textExpansion.keywords == ["hi", "sig"])
        try await harness.openSearch()
        #expect(Set(harness.rows.map(\.title)) == ["Greeting", "Sign Off"])
    }

    @Test func anIdleFeatureFollowsNoPermission() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = try await FeatureHarness.loaded([Fixture.greeting], fakes: fakes)
        #expect(!harness.feature.isWatchingPermission, "expansion is off, so nothing polls")
        #expect(fakes.permissions.openStreamCount == 0)

        // Turned on while Input Monitoring is missing: it waits for that grant, and only then.
        fakes.textExpansion.missingPermission = .inputMonitoring
        harness.context.settings[SnippetsSettings.expansionEnabled] = true
        try await harness.settle()
        #expect(harness.feature.isWatchingPermission)

        fakes.textExpansion.missingPermission = nil
        fakes.permissions.set(.inputMonitoring, to: .granted)
        try await harness.settle()
        #expect(harness.feature.expansion.status == .running)
        #expect(!harness.feature.isWatchingPermission, "the watch ends with the grant")

        // Taken away while running: the service says so, and the feature waits for it again.
        fakes.textExpansion.simulateStatus(.needsPermission(.accessibility))
        try await harness.settle()
        #expect(harness.feature.isWatchingPermission)
        await harness.deactivate()
        #expect(!harness.feature.isWatchingPermission, "no watch outlives the feature")
        #expect(fakes.permissions.openStreamCount == 0)
    }

    // MARK: Files from elsewhere

    @Test func aFileFromANewerVersionIsUsedButNeverOverwritten() async throws {
        let harness = FeatureHarness(SnippetsFeature.self)
        let newer = #"{"version": 9, "snippets": [{"id": "a", "name": "Kept", "text": "Kept text", "future": 1}]}"#
        try write(newer, to: harness.file)
        await harness.start()

        #expect(harness.library.index.snippets.map(\.name) == ["Kept"])
        #expect(harness.feature.status?.title == Strings.newerFileTitle)
        try await harness.openSearch()
        #expect(harness.page?.notice?.title == Strings.newerFileTitle)
        #expect(harness.rows.map(\.title) == ["Kept"], "its snippets still paste")

        harness.throwsActionErrors = false
        try harness.select(title: "Kept")
        try await harness.perform("pin")
        #expect(harness.toasts.last?.title == Strings.readOnlyTitle)
        #expect(try String(contentsOf: harness.file, encoding: .utf8) == newer, "the file is untouched")
    }

    @Test func importedKeywordsThatWouldMisfireAreLeftOut() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.signoff])
        let file = harness.fakes.storage.root.appending(path: "exchange.json")
        try write(
            """
            [
              {"name": "One Letter", "text": "fires on every e", "keyword": "e"},
              {"name": "Spaced", "text": "never typed", "keyword": "two words"},
              {"name": "Shadow", "text": "hides sig", "keyword": "si"},
              {"name": "Fine", "text": "fine text", "keyword": "fine"}
            ]
            """, to: file)
        try await harness.importAndConfirm([file])

        #expect(harness.toasts.last?.title == "Imported 4 Snippets")
        #expect(harness.toasts.last?.message == "Imported 3 snippets without their keywords.")
        #expect(harness.snippet(named: "One Letter")?.keyword == nil)
        #expect(harness.snippet(named: "Spaced")?.keyword == nil)
        #expect(harness.snippet(named: "Shadow")?.keyword == nil)
        #expect(harness.snippet(named: "Fine")?.keyword == "fine")
        #expect(harness.snippet(named: "Sign Off")?.keyword == "sig", "what the user has stays")
    }

    @Test func importIsNotFooledByDeepOrHugeFiles() async throws {
        let harness = try await FeatureHarness.loaded([])
        let file = harness.fakes.storage.root.appending(path: "deep.json")
        try write(String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000), to: file)
        try await harness.importAndConfirm([file])
        #expect(harness.library.index.isEmpty)
        #expect(harness.toasts.last?.message == "It is not a snippets file. Nothing was imported.")

        let entries = (0..<2_000).map { #"{"name": "Bulk \#($0)", "text": "text \#($0)"}"# }
        try write("[" + entries.joined(separator: ",") + "]", to: file)
        try await harness.importAndConfirm([file])
        #expect(harness.library.index.snippets.count == 2_000)
        #expect(harness.toasts.last?.title == "Imported 2000 Snippets")

        // More than 10,000 entries are refused before any is looked at.
        let tooMany = (0...10_000).map { _ in "{}" }
        try write("[" + tooMany.joined(separator: ",") + "]", to: file)
        try await harness.importAndConfirm([file])
        #expect(harness.toasts.last?.message == "It holds more than 10,000 entries. Nothing was imported.")
        #expect(harness.library.index.snippets.count == 2_000)
    }

    // MARK: Unicode

    @Test func unicodeKeywordsNamesAndCollectionsWork() async throws {
        let fakes = FakeServices()
        fakes.context(featureID: SnippetIDs.feature).settings[SnippetsSettings.expansionEnabled] = true
        let snippets = [
            Fixture.snippet("Grüße", "Viele Grüße", keyword: "gruß", collection: "Deutsch"),
            Fixture.snippet("Thumbs", "👍🏽", keyword: "👍👍"),
            Fixture.snippet("Arrow", "→", keyword: "->", collection: "符号"),
            Fixture.snippet("Hebrew", "שלום", keyword: "שש"),
        ]
        let harness = try await FeatureHarness.loaded(snippets, fakes: fakes)
        #expect(fakes.textExpansion.keywords == ["gruß", "👍👍", "->", "שש"])
        #expect(await fakes.textExpansion.type("👍👍") == .insert(Expansion("👍🏽")))
        #expect(await fakes.textExpansion.type("gru\u{DF}") == .insert(Expansion("Viele Grüße")))
        #expect(harness.instantAnswers(for: "שש").first?.rows.map(\.title) == ["Hebrew"])
        #expect(harness.instantAnswers(for: "👍").isEmpty, "only the whole keyword answers")
        try await harness.openSearch()
        #expect(harness.page?.dropdown?.options.map(\.title) == ["All Snippets", "Deutsch", "符号"])
        try await harness.setFilter("collection:符号")
        #expect(harness.rows.map(\.title) == ["Arrow"])
        #expect(harness.issues.isEmpty)
    }

    // MARK: Root search

    @Test func foreignQueriesAreTurnedAwayAtOnce() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting, Fixture.signoff])
        let queries = [
            "", " ", "h", "hi ", " hi", "HI", "sig\u{0}", String(repeating: "s", count: 10_000), "🙂", "\u{301}",
        ]
        let clock = ContinuousClock()
        for query in queries {
            let started = clock.now
            let answers = harness.instantAnswers(for: query)
            // Wide on purpose: this guards against work that grows with the input, not a few
            // milliseconds on a busy machine.
            #expect(clock.now - started < .milliseconds(250), "\(query.prefix(10)) is turned away quickly")
            #expect(answers.isEmpty, "\(query.prefix(10)) is not a keyword")
        }
        #expect(harness.instantAnswers(for: "hi").first?.rows.map(\.title) == ["Greeting"])
    }

    @Test func anEmptyLibraryAnswersEverywhere() async throws {
        let harness = try await FeatureHarness.loaded([])
        #expect(harness.instantAnswers(for: "anything").isEmpty)
        #expect(try await harness.catalogRows().isEmpty)
        try await harness.openSearch()
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == Strings.emptyTitle)
        harness.fakes.fileDialogs.saveLocation = harness.fakes.storage.root.appending(path: "out.json")
        try await harness.run(SnippetIDs.exportCommand)
        #expect(harness.toasts.last?.title == Strings.nothingToExport)
    }

    // MARK: Safety

    @Test func onlyATypedKeywordPastesWithoutAsking() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        for launch in [LaunchSource.deeplink, .root, .hotkey, .command, .suggestion] {
            try await harness.run(
                SnippetIDs.fillCommand, arguments: [SnippetIDs.snippetArgument: Fixture.greeting.id], launch: launch)
            #expect(harness.fakes.pasteboard.pastes.isEmpty, "\(launch) shows the form first")
            guard case .form(let form)? = harness.page?.page else {
                Issue.record("\(launch) did not show the form")
                continue
            }
            #expect(form.submitTitle == Strings.pasteSubmit)
            harness.pop()
        }
        try await harness.run(
            SnippetIDs.fillCommand, arguments: [SnippetIDs.snippetArgument: Fixture.greeting.id], launch: .deeplink)
        try await harness.submit()
        #expect(harness.fakes.pasteboard.pastedTexts == ["Hello there"], "the user pressed Paste Snippet")
        #expect(harness.issues.isEmpty)
    }

    // MARK: Handing text over

    @Test func textHandedOverWithoutANameGetsASuggestedOne() async throws {
        let harness = try await FeatureHarness.loaded([Fixture.greeting])
        try await harness.run(SnippetIDs.createCommand, arguments: [SnippetIDs.textArgument: "Meeting notes for today"])
        #expect(harness.page?.formValues.text(FormFields.name) == "Meeting notes for today")
        try await harness.run(SnippetIDs.createCommand, arguments: [SnippetIDs.textArgument: "Hello there"])
        #expect(harness.page?.formValues.text(FormFields.name) == "Hello there")
        try await harness.run(SnippetIDs.createCommand)
        #expect(harness.page?.formValues.text(FormFields.name) == "", "nothing handed over, nothing suggested")
    }

    @Test func expansionSkipsTheSamePasswordManagersAsClipboardHistory() {
        let excluded = Set(SnippetsSettings.excludedApps.defaultValue)
        for app in [
            "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
            "com.bitwarden.desktop", "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.lastpass.LastPass",
        ] {
            #expect(excluded.contains(app))
        }
    }
}
