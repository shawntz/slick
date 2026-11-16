import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import TranslateCommands

/// The simulated engine with every call recorded. With `holdsTranslations`, each translation
/// waits at a gate after it is recorded, as a slow model would, until the test opens the gate.
nonisolated final class RecordingEngine: TranslationEngine {
    private let base: any TranslationEngine
    private let calls = Mutex<[String]>([])
    private let cancelled = Mutex(0)
    private let gate: Gate?
    let entered: AsyncStream<String>
    private let enteredContinuation: AsyncStream<String>.Continuation

    init(_ base: any TranslationEngine = SimulatedTranslation(), holdsTranslations: Bool = false) {
        self.base = base
        gate = holdsTranslations ? Gate() : nil
        (entered, enteredContinuation) = AsyncStream.makeStream()
    }

    /// Every call, oldest first, such as "languages", "guess:Bonjour", "status:fr>en" or
    /// "translate:Bonjour:fr>en".
    var recorded: [String] { calls.withLock { $0 } }

    /// The calls that translate.
    var translations: [String] { recorded.filter { $0.hasPrefix("translate:") } }

    /// How many held translations stopped because their task was cancelled.
    var cancellations: Int { cancelled.withLock { $0 } }

    /// Lets every held translation, and every later one, go on.
    func open() async {
        await gate?.open()
    }

    @concurrent func supportedLanguages() async -> [LanguageTag] {
        record("languages")
        return await base.supportedLanguages()
    }

    @concurrent func preferredLanguages() async -> [String] {
        await base.preferredLanguages()
    }

    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess] {
        record("guess:" + text)
        return await base.guesses(for: text, hint: hint)
    }

    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus {
        record("status:\(source.code)>\(target.code)")
        return await base.status(from: source, to: target)
    }

    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
    {
        let call = "translate:\(text):\(source.code)>\(target.code)"
        record(call)
        enteredContinuation.yield(call)
        if let gate {
            await gate.wait()
            if Task.isCancelled { cancelled.withLock { $0 += 1 } }
        }
        try Task.checkCancellation()
        return try await base.translate(text, from: source, to: target)
    }

    private func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }
}

/// An engine whose every answer a test writes, for states the simulated table does not have.
nonisolated final class ScriptedEngine: TranslationEngine {
    let languages: [LanguageTag]
    let preferred: [String]
    let guessesByText: [String: [LanguageGuess]]
    let statusByPair: [String: PairStatus]
    let failure: EngineFailure?
    let translation: String

    init(
        languages: [String] = SimulatedTranslation.standardSupported, preferred: [String] = ["en-US"],
        guesses: [String: [LanguageGuess]] = [:], status: [String: PairStatus] = [:], failure: EngineFailure? = nil,
        translation: String = "Translated"
    ) {
        self.languages = languages.map(LanguageTag.init)
        self.preferred = preferred
        self.guessesByText = guesses
        self.statusByPair = status
        self.failure = failure
        self.translation = translation
    }

    @concurrent func supportedLanguages() async -> [LanguageTag] { languages }
    @concurrent func preferredLanguages() async -> [String] { preferred }

    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess] {
        guessesByText[text] ?? []
    }

    /// Pairs are written as "fr>de"; a pair not written is installed.
    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus {
        statusByPair["\(source.code)>\(target.code)"] ?? .installed
    }

    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
    {
        if let failure { throw failure }
        return translation
    }
}

/// Holds callers until it is opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A harness over the fakes with the engine replaced. Not yet activated.
func makeHarness(
    _ engine: any TranslationEngine = RecordingEngine(), fakes: FakeServices = FakeServices()
) -> FeatureHarness<TranslateFeature> {
    fakes.override(TranslationEngineKey.self, with: engine)
    return FeatureHarness(TranslateFeature.self, fakes: fakes)
}

/// A harness that is activated with its language list loaded, as soon after launch in the app.
func readyHarness(
    _ engine: any TranslationEngine = RecordingEngine(), fakes: FakeServices = FakeServices()
) async -> FeatureHarness<TranslateFeature> {
    let harness = makeHarness(engine, fakes: fakes)
    await harness.activate()
    await harness.feature.waitUntilReady()
    return harness
}

/// A catalog over the simulated languages, for pure tests.
func simulatedCatalog(
    supported: [String] = SimulatedTranslation.standardSupported, preferred: [String] = ["en-US"],
    display: String = "en_US_POSIX"
) -> LanguageCatalog {
    LanguageCatalog.make(
        supported: supported.map(LanguageTag.init), preferred: preferred, display: Locale(identifier: display))
}

extension FeatureHarness where F == TranslateFeature {
    /// The titles of the visible rows, in order.
    var titles: [String] { rows.map(\.title) }

    /// The root row for a query once its translation has arrived: asks, lets the pause pass, and
    /// waits for the provider's signal.
    func rootAnswer(_ query: String) async throws -> Row? {
        let first = instantAnswers(for: query).first?.rows.first
        guard first?.title == TranslateStrings.translating else { return first }
        await fakes.clock.waitForSleepers()
        fakes.clock.advance(by: KeywordProvider.debounce)
        return try await instantAnswersAfterChange(for: query).first?.rows.first
    }

    /// The payload of a row.
    func payload(of row: Row?) throws -> TranslationRow {
        let row = try #require(row)
        return try #require(try row.payload?.decode(TranslationRow.self))
    }

    /// Opens the Translate page with this text typed.
    func openPage(typing text: String) async throws {
        try await run(TranslateFeature.translateID)
        try await setQuery(text)
    }
}

extension LanguageTag {
    /// A tag for tests, such as `.tag("fr")`.
    static func tag(_ identifier: String) -> LanguageTag { LanguageTag(identifier) }
}
