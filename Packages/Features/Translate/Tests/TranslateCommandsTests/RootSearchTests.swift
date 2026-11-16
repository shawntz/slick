import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

@Suite("Root search", .timeLimit(.minutes(1)))
struct RootSearchTests {
    @Test func keywordsAreFoundOnTheirFirstByteAndNeedText() {
        #expect(RootKeyword.text(in: "tr Bonjour") == "Bonjour")
        #expect(RootKeyword.text(in: "TR Bonjour") == "Bonjour")
        #expect(RootKeyword.text(in: "translate Bonjour") == "Bonjour")
        #expect(RootKeyword.text(in: "Translate  Bonjour") == " Bonjour")
        for query in [
            "tr", "tr ", "tr   ", "translate", "translate ", "trash", "terminal", "tra Bonjour", "safari", "", "t",
        ] {
            #expect(RootKeyword.text(in: query) == nil, "\(query)")
        }
    }

    @Test func aTrailingLanguageNameChoosesTheTarget() {
        let catalog = simulatedCatalog(preferred: ["de-DE"])
        #expect(
            RootKeyword.request("Good morning to French", catalog: catalog)
                == RootRequest(text: "Good morning", target: .tag("fr")))
        #expect(
            RootKeyword.request("Good morning TO französisch ", catalog: catalog)
                == RootRequest(text: "Good morning", target: .tag("fr")))
        #expect(
            RootKeyword.request("I want to go home", catalog: catalog)
                == RootRequest(text: "I want to go home", target: nil), "a word that is no language stays text")
        #expect(
            RootKeyword.request("to French", catalog: catalog) == RootRequest(text: "to French", target: nil),
            "with nothing before it, it is the text")
        #expect(
            RootKeyword.request("go to Japanese to Spanish", catalog: catalog)
                == RootRequest(text: "go to Japanese", target: .tag("es")), "the last one counts")
        #expect(
            RootKeyword.request("Good morning to english united kingdom", catalog: catalog)
                == RootRequest(text: "Good morning", target: .tag("en-GB")))
    }

    @Test func otherQueriesAreRefusedAndNothingStarts() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        for query in ["safari", "t", "tr", "terminal", "trash", "tr ", "Translate", "こんにちは"] {
            #expect(harness.instantAnswers(for: query).isEmpty, "\(query)")
        }
        #expect(harness.fakes.clock.sleeperCount == 0)
        #expect(engine.recorded == ["languages"])
    }

    @Test func theRowSaysItIsTranslatingThenFillsWhenTheAnswerArrives() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        let answers = harness.instantAnswers(for: "tr Bonjour")
        let first = try #require(answers.first)
        #expect(first.claimsTop)
        #expect(first.rows.map(\.title) == ["Translating…"])
        #expect(first.rows.first?.subtitle == "Bonjour")
        #expect(first.rows.first?.memory == .never)
        #expect(engine.translations.isEmpty, "nothing starts before the pause")

        await harness.fakes.clock.waitForSleepers()
        harness.fakes.clock.advance(by: KeywordProvider.debounce)
        let filled = try #require(try await harness.instantAnswersAfterChange(for: "tr Bonjour").first?.rows.first)
        #expect(filled.title == "Good morning")
        #expect(filled.subtitle == "French \u{2192} English (United States)")
        #expect(filled.memory == .never, "root search remembers nothing")
        #expect(filled.id == first.rows.first?.id, "the row fills in place")
        #expect(engine.translations == ["translate:Bonjour:fr>en"])

        // Asked again, the answer is there at once.
        #expect(harness.instantAnswers(for: "tr Bonjour").first?.rows.first?.title == "Good morning")
        #expect(engine.translations.count == 1)
    }

    @Test func toAndALanguageNameTranslateIntoThatLanguage() async throws {
        let harness = await readyHarness()
        let row = try await harness.rootAnswer("tr Seven paper boats to japanese")
        #expect(row?.title == "七つの紙の船")
        #expect(try harness.payload(of: row).requested == .tag("ja"))
    }

    @Test func typingOnCancelsTheEarlierTranslation() async throws {
        let engine = RecordingEngine(holdsTranslations: true)
        let harness = await readyHarness(engine)
        _ = harness.instantAnswers(for: "tr Bonjour")
        await harness.fakes.clock.waitForSleepers()
        harness.fakes.clock.advance(by: KeywordProvider.debounce)
        var entered = engine.entered.makeAsyncIterator()
        #expect(await entered.next() == "translate:Bonjour:fr>en")
        // The user types on: the held translation is cancelled and its answer never shows.
        #expect(harness.instantAnswers(for: "tr Buenos días").first?.rows.first?.title == "Translating…")
        await engine.open()
        await harness.fakes.clock.waitForSleepers()
        harness.fakes.clock.advance(by: KeywordProvider.debounce)
        let row = try await harness.instantAnswersAfterChange(for: "tr Buenos días").first?.rows.first
        #expect(row?.title == "Good morning")
        #expect(engine.cancellations == 1)
        #expect(harness.instantAnswers(for: "tr Bonjour").first?.rows.first?.title == "Translating…")
    }

    @Test func leavingTheKeywordStopsTheWait() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        _ = harness.instantAnswers(for: "tr Bonjour")
        await harness.fakes.clock.waitForSleepers()
        #expect(harness.instantAnswers(for: "safari").isEmpty)
        harness.fakes.clock.advance(by: .seconds(1))
        try await harness.settle()
        #expect(engine.translations.isEmpty)
        #expect(harness.fakes.clock.sleeperCount == 0)
    }

    @Test func aRowThatAsksForADownloadIsAskedAgainNextTime() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        let row = try await harness.rootAnswer("tr Bonjour to German")
        #expect(row?.title == "Download German to Translate")
        let actions = harness.rootActions(for: try #require(row))
        #expect(actions.map(\.title) == ["Open Translation Languages", "Open in Translate", "Copy Original"])
        try await harness.performRoot("open-language-settings", on: try #require(row))
        #expect(harness.fakes.workspace.opened.count == 1)
        // Another query, then back: the pair is checked again, since the user may have downloaded.
        _ = try await harness.rootAnswer("tr Bonjour")
        let statusChecks = engine.recorded.filter { $0 == "status:fr>de" }.count
        _ = try await harness.rootAnswer("tr Bonjour to German")
        #expect(engine.recorded.filter { $0 == "status:fr>de" }.count > statusChecks)
    }

    @Test func rootRowsOfferCopyPasteSwapAndThePage() async throws {
        let harness = await readyHarness()
        let row = try #require(try await harness.rootAnswer("tr La bouilloire bleue chante to Spanish"))
        let actions = harness.rootActions(for: row)
        #expect(
            actions.map(\.title) == [
                "Copy Translation", "Paste Translation", "Swap Languages", "Copy Original", "Open in Translate",
            ])
        try await harness.performRoot("copy-translation", on: row)
        #expect(harness.fakes.pasteboard.copiedTexts == ["La tetera azul canta"])

        try await harness.performRoot("open-in-translate", on: row)
        #expect(harness.page?.query == "La bouilloire bleue chante")
        #expect(harness.page?.filter == LanguageTag("es").identifier)
        #expect(harness.titles == ["La tetera azul canta"])
        harness.pop()

        let outcome = try await harness.performRoot("swap-languages", on: row)
        #expect(outcome.kind == .push)
        #expect(harness.page?.query == "La tetera azul canta")
        #expect(harness.page?.filter == LanguageTag("fr").identifier)
        #expect(harness.titles == ["La bouilloire bleue chante"])
        #expect(harness.issues.isEmpty)
    }

    @Test func aLoadingRowOpensThePage() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.instantAnswers(for: "tr Bonjour").first?.rows.first)
        #expect(harness.rootActions(for: row).map(\.title) == ["Open in Translate", "Copy Original"])
        try await harness.performRoot("open-in-translate", on: row)
        #expect(harness.titles == ["Good morning"])
    }

    @Test func longTextIsSentToThePage() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        let text = String(repeating: "Bonjour ", count: 200)
        let row = try #require(harness.instantAnswers(for: "tr " + text).first?.rows.first)
        #expect(row.title == "Text Too Long")
        #expect(row.subtitle == "Root search translates short text. Open Translate for longer text.")
        #expect(harness.fakes.clock.sleeperCount == 0)
        #expect(try harness.payload(of: row).original == text)
        #expect(harness.rootActions(for: row).first?.title == "Open in Translate")
        // A paste far past the page's own limit is carried only as far as the page reads.
        let huge = String(repeating: "a", count: 50_000)
        let hugeRow = harness.instantAnswers(for: "tr " + huge).first?.rows.first
        #expect(try harness.payload(of: hugeRow).original.utf8.count == TranslationText.maximumBytes + 1)
        #expect(engine.translations.isEmpty)
    }

    @Test func theKeywordSettingTurnsTheAnswerOff() async throws {
        let harness = await readyHarness()
        harness.context.settings[TranslateSettings.keywords] = false
        #expect(harness.instantAnswers(for: "tr Bonjour").isEmpty)
        harness.context.settings[TranslateSettings.keywords] = true
        #expect(harness.instantAnswers(for: "tr Bonjour").first?.rows.first?.title == "Translating…")
    }

    @Test func aNewLanguageInSettingsForgetsEarlierAnswers() async throws {
        let harness = await readyHarness()
        #expect(try await harness.rootAnswer("tr Good morning")?.title == "Already in English (United States)")
        harness.context.settings[TranslateSettings.secondTarget] = LanguageTag("fr").identifier
        try await harness.settle()
        #expect(try await harness.rootAnswer("tr Good morning")?.title == "Bonjour")
        harness.context.settings[TranslateSettings.target] = LanguageTag("es").identifier
        try await harness.settle()
        #expect(try await harness.rootAnswer("tr Good morning")?.title == "Buenos días")
    }

    @Test func aRowWaitsForTheLanguageListAndFillsWhenItArrives() async throws {
        let harness = makeHarness()
        let first = harness.instantAnswers(for: "tr Bonjour").first?.rows.first
        #expect(first?.title == "Translating…")
        await harness.activate()
        _ = try await harness.instantAnswersAfterChange(for: "tr Bonjour")
        #expect(try await harness.rootAnswer("tr Bonjour")?.title == "Good morning")
    }

    @Test func titlesStayOnOneLineAndDrawInTheirStoredOrder() async throws {
        let engine = ScriptedEngine(
            guesses: ["Hallo": [LanguageGuess("de", probability: 0.9)]], translation: "line one\nline\u{202E}two")
        let harness = await readyHarness(engine)
        let row = try #require(try await harness.rootAnswer("tr Hallo"))
        #expect(row.title == "line one line\u{FFFD}two")
    }
}
