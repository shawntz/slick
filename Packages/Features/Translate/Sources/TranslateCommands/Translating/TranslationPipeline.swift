import Foundation

/// What came of one request to translate a text.
nonisolated enum TranslationOutcome: Codable, Hashable, Sendable {
    /// The translation, with the language the text was recognized in.
    case translated(source: LanguageTag, target: LanguageTag, text: String)
    /// The pair needs a language that is not installed. `missing` names it, or both languages
    /// when the engine could not tell which one is missing.
    case needsDownload(source: LanguageTag, target: LanguageTag, missing: [LanguageTag])
    /// The text is in a language the Mac cannot translate, as the recognizer named it.
    case unsupportedLanguage(String)
    /// The Mac cannot translate between the two languages.
    case unsupportedPair(source: LanguageTag, target: LanguageTag)
    /// The text is already in the language asked for, and there is no other one to use.
    case alreadyIn(LanguageTag)
    /// No language was recognized.
    case notRecognized
    /// The text is longer than this place translates.
    case tooLong
    /// The Mac offers no languages at all.
    case unavailable
    /// The system could not translate, with its words.
    case failed(String)

    /// The translated text, when there is one.
    var translation: String? {
        if case .translated(_, _, let text) = self { return text }
        return nil
    }
}

/// What a request needs besides its text: the languages, decided on the main actor from the
/// settings and the page, then carried off it.
nonisolated struct TranslationPlan: Sendable {
    var catalog: LanguageCatalog
    /// The language asked for: typed after "to", picked in the menu, or the setting.
    var target: LanguageTag?
    /// True when the user named the target for this text, as with "to French" in root search. Text
    /// already in that language is then not sent to the second language.
    var isExplicit: Bool
    /// The language for text that is already in the target, from the settings.
    var second: LanguageTag?
    /// A language the text is probably in, such as the one it was just translated into.
    var hint: LanguageTag?
}

/// The steps of one translation, run off the main thread: recognize the language, choose the
/// target, check the pair, translate. Every step stops when the calling task is cancelled.
nonisolated enum TranslationPipeline {
    @concurrent static func run(_ text: String, plan: TranslationPlan, engine: any TranslationEngine) async throws
        -> TranslationOutcome
    {
        guard var target = plan.target else { return .unavailable }
        let guesses = await engine.guesses(for: text, hint: plan.hint)
        try Task.checkCancellation()
        let source: LanguageTag
        switch plan.catalog.source(from: guesses) {
        case .unknown: return .notRecognized
        case .unsupported(let identifier): return .unsupportedLanguage(identifier)
        case .supported(let tag): source = tag
        }
        if source.isSameLanguage(as: target) {
            guard !plan.isExplicit, let second = plan.second, !second.isSameLanguage(as: source) else {
                return .alreadyIn(target)
            }
            target = second
        }
        switch await engine.status(from: source, to: target) {
        case .unsupported:
            return .unsupportedPair(source: source, target: target)
        case .notInstalled:
            return try await needsDownload(source: source, target: target, plan: plan, engine: engine)
        case .installed:
            break
        }
        try Task.checkCancellation()
        do {
            let translation = try await engine.translate(text, from: source, to: target)
            try Task.checkCancellation()
            guard TranslationText.hasVisibleText(translation) else { return .failed(TranslateStrings.emptyTranslation) }
            return .translated(source: source, target: target, text: translation)
        } catch EngineFailure.notInstalled {
            try Task.checkCancellation()
            return try await needsDownload(source: source, target: target, plan: plan, engine: engine)
        } catch EngineFailure.unsupported {
            return .unsupportedPair(source: source, target: target)
        } catch EngineFailure.failed(let message) {
            return .failed(message)
        }
    }

    /// Which language of a pair to download. The engine only says a pair is not installed, so each
    /// side is tried against another language: when that pair is installed, that side is on the
    /// Mac and the other one is missing. When no pair tells, both are named.
    @concurrent static func needsDownload(
        source: LanguageTag, target: LanguageTag, plan: TranslationPlan, engine: any TranslationEngine
    ) async throws -> TranslationOutcome {
        var others: [LanguageTag] = []
        let candidates = [plan.catalog.automaticTarget, plan.catalog.english, plan.second, plan.target]
        for candidate in candidates.compactMap(\.self)
        where !candidate.isSameLanguage(as: source) && !candidate.isSameLanguage(as: target)
            && !others.contains(candidate)
        {
            others.append(candidate)
        }
        var missing = [source, target]
        for other in others {
            try Task.checkCancellation()
            if await engine.status(from: source, to: other) == .installed {
                missing = [target]
                break
            }
            if await engine.status(from: other, to: target) == .installed {
                missing = [source]
                break
            }
        }
        try Task.checkCancellation()
        return .needsDownload(source: source, target: target, missing: missing)
    }
}
