import Foundation
import Translation

/// The live engine: Apple's Translation framework with the languages already installed, and the
/// NaturalLanguage framework's recognizer through ``LanguageRecognizer``.
///
/// Every call here is live code that only the app runs. Tests and scenarios get
/// ``SimulatedTranslation``.
///
/// - Nothing here prompts, downloads or sends anything over the network. Whether the system's
///   translation service stays on the Mac has not been watched in a live run. A session made with
///   `TranslationSession(installedSource:target:)` translates with installed languages only: it
///   cannot ask for a download, and it throws `TranslationError.notInstalled` when a language is
///   missing. No SwiftUI view is needed for it, so there is no host window.
/// - Each translation makes its own session in a `@concurrent` function and drops it after, so the
///   session, which is not `Sendable`, never crosses a thread. A task that is cancelled while the
///   framework works cancels the session's requests.
/// - `LanguageAvailability` answers which languages exist and whether a pair is installed. It
///   reads only the system's own catalog of languages.
nonisolated final class SystemTranslation: TranslationEngine {
    init() {}

    @concurrent func supportedLanguages() async -> [LanguageTag] {
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        return languages.map(LanguageTag.init)
    }

    @concurrent func preferredLanguages() async -> [String] {
        Locale.preferredLanguages
    }

    @concurrent func guesses(for text: String, hint: LanguageTag?) async -> [LanguageGuess] {
        LanguageRecognizer.guesses(for: text, hint: hint)
    }

    @concurrent func status(from source: LanguageTag, to target: LanguageTag) async -> PairStatus {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source.language, to: target.language)
        switch status {
        case .installed: return .installed
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    @concurrent func translate(_ text: String, from source: LanguageTag, to target: LanguageTag) async throws
        -> String
    {
        try Task.checkCancellation()
        let session = TranslationSession(installedSource: source.language, target: target.language)
        let canceller = SessionCanceller(session)
        do {
            let response = try await withTaskCancellationHandler {
                try await session.translate(text)
            } onCancel: {
                canceller.cancel()
            }
            try Task.checkCancellation()
            return response.targetText
        } catch {
            try Task.checkCancellation()
            throw Self.failure(for: error)
        }
    }

    /// The feature's reading of an error the framework threw.
    static func failure(for error: any Error) -> any Error {
        if error is CancellationError || error is EngineFailure { return error }
        if TranslationError.alreadyCancelled ~= error { return CancellationError() }
        if TranslationError.notInstalled ~= error { return EngineFailure.notInstalled }
        if TranslationError.unsupportedSourceLanguage ~= error || TranslationError.unsupportedTargetLanguage ~= error
            || TranslationError.unsupportedLanguagePairing ~= error
        {
            return EngineFailure.unsupported
        }
        let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        return EngineFailure.failed(message)
    }
}

/// Hands a session's `cancel()` to a cancellation handler, which may run on any thread. The
/// framework offers `cancel()` to stop requests in flight from outside them, and the handler makes
/// that one call.
nonisolated final class SessionCanceller: @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func cancel() {
        session.cancel()
    }
}
