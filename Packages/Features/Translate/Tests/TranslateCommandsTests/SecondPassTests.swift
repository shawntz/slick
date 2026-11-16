import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

/// A second engineer's attempts to break the feature: the feature's own command typed in root
/// search, the feature switched off mid-translation, every action on every kind of row, and every
/// flow watched for a request, a process or a download.
@Suite("Second pass", .timeLimit(.minutes(1)))
struct SecondPassTests {
    // MARK: Root search

    /// Typing the title of Translate Selection is a search for that command. A translation row
    /// that claims the top would take its place, and Return would open the page on the word
    /// "selection" instead of running the command.
    @Test func typingTheFeaturesOwnCommandTitleTranslatesNothing() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        for query in [
            "translate s", "translate se", "Translate Sel", "translate selectio", "translate selection",
            "TRANSLATE SELECTION",
        ] {
            #expect(harness.instantAnswers(for: query).isEmpty, "\(query)")
            #expect(RootKeyword.text(in: query) == nil, "\(query)")
        }
        #expect(harness.fakes.clock.sleeperCount == 0, "no translation waits to start")
        #expect(engine.translations.isEmpty)
        // Past the title, and with the short keyword, the word is text again.
        #expect(RootKeyword.text(in: "translate selections") == "selections")
        #expect(RootKeyword.text(in: "translate selection now") == "selection now")
        #expect(RootKeyword.text(in: "tr selection") == "selection")
        #expect(RootKeyword.text(in: "translate sun") == "sun")
        #expect(harness.instantAnswers(for: "tr selection").first?.rows.first?.title == "Translating…")
    }

    /// Turning the feature off while a root translation runs cancels it at the engine, and an
    /// answer that comes back anyway is never kept or shown.
    @Test func switchingTheFeatureOffMidTranslationCancelsItAndKeepsNothing() async throws {
        let base = RecordingEngine(holdsTranslations: true)
        let engine = ExitWatchingEngine(base)
        let harness = await readyHarness(engine)
        _ = harness.instantAnswers(for: "tr Bonjour")
        await harness.fakes.clock.waitForSleepers()
        harness.fakes.clock.advance(by: KeywordProvider.debounce)
        var entered = base.entered.makeAsyncIterator()
        #expect(await entered.next() == "translate:Bonjour:fr>en")
        let changes = try #require(harness.feature.provider.answersChanged)
        let signalled = changes.generation

        await harness.deactivate()
        await base.open()
        var exits = engine.exits.makeAsyncIterator()
        #expect(await exits.next() == true, "the translation ended cancelled")
        #expect(base.cancellations == 1)
        #expect(changes.generation == signalled, "root search was not asked to show an answer")

        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(harness.instantAnswers(for: "tr Bonjour").first?.rows.first?.title == "Translating…")
    }

    // MARK: Every action on every kind of row

    /// Every outcome a root row can show, and every action it offers, runs without a problem the
    /// validator finds, and only Open Translation Languages opens anything.
    @Test func everyActionOnEveryKindOfRootRowRuns() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        harness.grantsMissingPermissions = true
        let long = "tr " + String(repeating: "Bonjour ", count: 200)
        let loading = try #require(harness.instantAnswers(for: "tr Seven paper boats").first?.rows.first)
        #expect(loading.title == "Translating…")
        var rows: [(query: String, row: Row)] = [("tr Seven paper boats", loading)]
        for query in [
            "tr Bonjour", "tr Bonjour to German", "tr Good morning", "tr xyzzy plugh", "tr Bláa ketillinn syngur",
            long,
        ] {
            rows.append((query, try #require(try await harness.rootAnswer(query), "\(query)")))
        }
        #expect(
            rows.map(\.row.title) == [
                "Translating…", "Good morning", "Download German to Translate", "Already in English (United States)",
                "Language Not Recognized", "Can’t Translate Icelandic", "Text Too Long",
            ])
        var opened = 0
        for (query, row) in rows {
            let actions = harness.rootActions(for: row)
            #expect(!actions.isEmpty, "\(row.title)")
            for action in actions {
                try await harness.perform(action, row: row, query: query, launch: .root)
                if action.id == "open-language-settings" { opened += 1 }
            }
        }
        #expect(opened == 1)
        #expect(harness.fakes.workspace.opened.map(\.absoluteString) == [TranslatePages.languageSettingsLink])
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    // MARK: Nothing leaves the Mac

    /// Every flow, from activation to a deep link, runs no process, sends no request, and opens
    /// nothing but Translation Languages when the user asks for it.
    @Test func noFlowSendsARequestRunsAProcessOrOpensAnything() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        harness.grantsMissingPermissions = true
        _ = try await harness.rootAnswer("tr Bonjour")
        _ = try await harness.rootAnswer("tr Bonjour to German")
        try await harness.run("translate", launch: .deeplink)
        try await harness.openPage(typing: "La bouilloire bleue chante")
        try await harness.setFilter(LanguageTag("de").identifier)
        try await harness.setFilter(LanguageTag("es").identifier)
        for action in harness.actions() where action.id != "swap-languages" {
            try await harness.perform(action, row: harness.selectedRow)
        }
        harness.fakes.selection.selection = .text("Sept bateaux en papier")
        try await harness.run(TranslateFeature.selectionID, launch: .hotkey)
        try await harness.run(TranslateFeature.selectionID, launch: .deeplink)
        harness.closePanel()
        try await harness.openPanel()
        await harness.deactivate()
        await harness.activate()
        await harness.feature.waitUntilReady()
        try await harness.settle()

        #expect(harness.fakes.http.requests.isEmpty)
        #expect(harness.fakes.processes.runs.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.workspace.launched.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        #expect(harness.fakes.selection.reads == 1, "only the hotkey run read the selection")
    }

    /// Text made of controls, invisible characters and direction overrides is never translated,
    /// and text with them inside shows on one line in its stored order.
    @Test func hostileTextIsCleanedOrRefused() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        for query in ["tr \u{200B}\u{200B}", "tr \u{0}\u{1}\u{7F}", "tr \u{202E}", "tr \u{FEFF}\t"] {
            let row = try await harness.rootAnswer(query)
            #expect(row?.title == "Language Not Recognized", "\(query.debugDescription)")
        }
        #expect(engine.translations.isEmpty)
        try await harness.openPage(typing: "\u{202E}Bonjour\u{0}")
        let title = try #require(harness.rows.first?.title)
        #expect(!title.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{0}" })
    }
}

/// An engine that reports each translation as it ends, and whether its task was cancelled then,
/// so a test can wait for a translation it no longer owns.
nonisolated final class ExitWatchingEngine: TranslationEngine {
    private let base: any TranslationEngine
    let exits: AsyncStream<Bool>
    private let exitContinuation: AsyncStream<Bool>.Continuation

    init(_ base: any TranslationEngine) {
        self.base = base
        (exits, exitContinuation) = AsyncStream.makeStream()
    }

    @concurrent func supportedLanguages() async -> [LanguageTag] { await base.supportedLanguages() }
    @concurrent func preferredLanguages() async -> [String] { await base.preferredLanguages() }

    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess] {
        await base.guesses(for: text, hint: hint)
    }

    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus {
        await base.status(from: source, to: target)
    }

    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
    {
        defer { exitContinuation.yield(Task.isCancelled) }
        return try await base.translate(text, from: source, to: target)
    }
}
