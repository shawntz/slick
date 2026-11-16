import Foundation
import Kit
import Testing

@testable import TranslateCommands

@Suite("Pipeline", .timeLimit(.minutes(1)))
struct PipelineTests {
    let catalog = simulatedCatalog()

    func plan(
        _ target: String?, explicit: Bool = false, second: String? = nil, hint: String? = nil,
        catalog: LanguageCatalog? = nil
    ) -> TranslationPlan {
        TranslationPlan(
            catalog: catalog ?? self.catalog, target: target.map(LanguageTag.init), isExplicit: explicit,
            second: second.map(LanguageTag.init), hint: hint.map(LanguageTag.init))
    }

    func run(_ text: String, _ plan: TranslationPlan, engine: any TranslationEngine = SimulatedTranslation())
        async throws -> TranslationOutcome
    {
        try await TranslationPipeline.run(text, plan: plan, engine: engine)
    }

    @Test func anInstalledPairTranslates() async throws {
        let outcome = try await run("La bouilloire bleue chante", plan("en-US"))
        #expect(outcome == .translated(source: .tag("fr"), target: .tag("en-US"), text: "The blue kettle sings"))
        #expect(outcome.translation == "The blue kettle sings")
        let japanese = try await run("Seven paper boats", plan("ja"))
        #expect(japanese.translation == "七つの紙の船")
    }

    @Test func aMissingLanguageIsNamedAndNothingIsTranslated() async throws {
        let engine = RecordingEngine()
        let outcome = try await run("Bonjour", plan("de"), engine: engine)
        #expect(outcome == .needsDownload(source: .tag("fr"), target: .tag("de"), missing: [.tag("de")]))
        #expect(engine.translations.isEmpty)
        let fromGerman = try await run("Guten Morgen", plan("es"), engine: engine)
        #expect(fromGerman == .needsDownload(source: .tag("de"), target: .tag("es"), missing: [.tag("de")]))
    }

    @Test func whenNoPairTellsWhichIsMissingBothAreNamed() async throws {
        let engine = SimulatedTranslation(installed: [])
        let outcome = try await run("Bonjour", plan("de"), engine: engine)
        #expect(outcome == .needsDownload(source: .tag("fr"), target: .tag("de"), missing: [.tag("fr"), .tag("de")]))
    }

    @Test func aLanguageTheMacCannotTranslateIsNamed() async throws {
        let outcome = try await run("Bláa ketillinn syngur", plan("en-US"))
        #expect(outcome == .unsupportedLanguage("is"))
    }

    @Test func aPairTheMacRefusesIsNamed() async throws {
        let engine = SimulatedTranslation(unsupportedPairs: [["ja", "es"]])
        let outcome = try await run("七つの紙の船", plan("es"), engine: engine)
        #expect(outcome == .unsupportedPair(source: .tag("ja"), target: .tag("es")))
    }

    @Test func textNoLanguageMatchesIsNotRecognized() async throws {
        #expect(try await run("qzx vbnm", plan("en-US")) == .notRecognized)
    }

    @Test func textAlreadyInTheTargetGoesToTheSecondLanguage() async throws {
        let outcome = try await run("Good morning", plan("en-US", second: "fr"))
        #expect(outcome == .translated(source: .tag("en-US"), target: .tag("fr"), text: "Bonjour"))
        let british = try await run("Good morning", plan("en-GB", second: "es"))
        #expect(british.translation == "Buenos días", "British and American English are one language here")
    }

    @Test func textAlreadyInTheTargetWithoutASecondLanguageSaysSo() async throws {
        #expect(try await run("Good morning", plan("en-US")) == .alreadyIn(.tag("en-US")))
        #expect(try await run("Good morning", plan("en-US", second: "en-GB")) == .alreadyIn(.tag("en-US")))
    }

    @Test func aTargetTheUserNamedIsKeptEvenForTextInIt() async throws {
        let outcome = try await run("Bonjour", plan("fr", explicit: true, second: "es"))
        #expect(outcome == .alreadyIn(.tag("fr")))
    }

    @Test func noLanguagesMeansUnavailable() async throws {
        let empty = simulatedCatalog(supported: [])
        #expect(try await run("Bonjour", plan(nil, catalog: empty)) == .unavailable)
    }

    @Test func engineFailuresBecomeOutcomes() async throws {
        let guesses = ["Hallo": [LanguageGuess("de", probability: 0.9)]]
        // The status said installed, then the framework said otherwise: English, installed with
        // French but not with German, tells that German is the one missing.
        let notInstalled = ScriptedEngine(
            guesses: guesses, status: ["de>fr": .installed, "de>en": .notInstalled, "en>fr": .installed],
            failure: .notInstalled)
        let outcome = try await run("Hallo", plan("fr"), engine: notInstalled)
        #expect(outcome == .needsDownload(source: .tag("de"), target: .tag("fr"), missing: [.tag("de")]))
        let refused = ScriptedEngine(guesses: guesses, failure: .unsupported)
        #expect(
            try await run("Hallo", plan("fr"), engine: refused)
                == .unsupportedPair(source: .tag("de"), target: .tag("fr")))
        let failed = ScriptedEngine(guesses: guesses, failure: .failed("The model is busy."))
        #expect(try await run("Hallo", plan("fr"), engine: failed) == .failed("The model is busy."))
        let empty = ScriptedEngine(guesses: guesses, translation: " \u{200B} ")
        #expect(try await run("Hallo", plan("fr"), engine: empty) == .failed(TranslateStrings.emptyTranslation))
    }

    @Test func aStatusSaysUnsupportedBeforeAnythingIsTranslated() async throws {
        let engine = ScriptedEngine(
            guesses: ["Hallo": [LanguageGuess("de", probability: 0.9)]], status: ["de>fr": .unsupported])
        #expect(
            try await run("Hallo", plan("fr"), engine: engine)
                == .unsupportedPair(source: .tag("de"), target: .tag("fr")))
    }

    /// A cancelled request stops before the engine translates, and its answer never comes back.
    @Test func cancellationStopsTheTranslation() async throws {
        let engine = RecordingEngine(holdsTranslations: true)
        let plan = plan("en-US")
        let task = Task { try await TranslationPipeline.run("Bonjour", plan: plan, engine: engine) }
        var entered = engine.entered.makeAsyncIterator()
        #expect(await entered.next() == "translate:Bonjour:fr>en")
        task.cancel()
        await engine.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(engine.cancellations == 1)
    }
}
