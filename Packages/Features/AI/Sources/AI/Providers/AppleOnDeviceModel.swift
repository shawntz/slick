import Foundation
import FoundationModels
import Kit

/// Apple's on-device model through the FoundationModels framework. The live implementation, used
/// only in the app.
///
/// `status()` reads `SystemLanguageModel.default.availability`, which never prompts. `respond`
/// opens a fresh `LanguageModelSession` per answer with the system prompt as its instructions and
/// streams the response. The framework hands back the whole answer so far on each step; this sends
/// on only the new part. Nothing leaves the Mac.
///
/// Tests never run this: they override ``OnDeviceModelKey``, and other runs get
/// ``SimulatedOnDeviceModel``.
nonisolated final class AppleOnDeviceModel: OnDeviceModelService {
    init() {}

    @concurrent func status() async -> OnDeviceStatus {
        Self.status(of: SystemLanguageModel.default.availability)
    }

    func respond(instructions: String, prompt: String, maximumTokens: Int?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions.isEmpty ? nil : instructions)
                    let options = GenerationOptions(maximumResponseTokens: maximumTokens)
                    var shown = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let text: String = snapshot.content
                        guard text.utf8.count > shown.utf8.count, text.utf8.starts(with: shown.utf8) else { continue }
                        continuation.yield(String(decoding: text.utf8.dropFirst(shown.utf8.count), as: UTF8.self))
                        shown = text
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.failure(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func status(of availability: SystemLanguageModel.Availability) -> OnDeviceStatus {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .notEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .notReady
            @unknown default: return .notReady
            }
        }
    }

    /// Words for a framework error. macOS 27 throws the newer error types; macOS 26 throws
    /// `GenerationError`.
    static func failure(for error: any Error) -> any Error {
        if error is CancellationError { return error }
        if #available(macOS 27.0, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded: return Strings.Failures.onDeviceTooLong
                case .guardrailViolation, .refusal: return Strings.Failures.onDeviceDeclined
                case .unsupportedLanguageOrLocale: return Strings.Failures.onDeviceLanguage
                case .rateLimited, .timeout: return Strings.Failures.onDeviceBusy
                default: return Strings.Failures.onDeviceFailed
                }
            }
            if error is SystemLanguageModel.Error { return Strings.Failures.onDeviceNotReady }
            if error is LanguageModelSession.Error { return Strings.Failures.onDeviceBusy }
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize: return Strings.Failures.onDeviceTooLong
            case .guardrailViolation, .refusal: return Strings.Failures.onDeviceDeclined
            case .unsupportedLanguageOrLocale: return Strings.Failures.onDeviceLanguage
            case .assetsUnavailable: return Strings.Failures.onDeviceNotReady
            case .rateLimited, .concurrentRequests: return Strings.Failures.onDeviceBusy
            default: return Strings.Failures.onDeviceFailed
            }
        }
        return Strings.Failures.onDeviceFailed
    }
}

/// A stand-in for the on-device model in scenarios, self-tests and benchmarks: always available,
/// and it answers every prompt with the same sample text, a few words at a time.
nonisolated final class SimulatedOnDeviceModel: OnDeviceModelService {
    init() {}

    @concurrent func status() async -> OnDeviceStatus { .available }

    func respond(instructions: String, prompt: String, maximumTokens: Int?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            var words = Strings.Simulated.answer.split(separator: " ", omittingEmptySubsequences: false).map(
                String.init)
            for index in words.indices.dropLast() { words[index] += " " }
            for word in words { continuation.yield(word) }
            continuation.finish()
        }
    }
}
