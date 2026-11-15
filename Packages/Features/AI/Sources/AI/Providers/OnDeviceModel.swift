import Foundation
import Kit

/// Whether Apple's on-device model can answer on this Mac.
nonisolated enum OnDeviceStatus: Hashable, Sendable {
    case available
    /// This Mac cannot run it.
    case notEligible
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// The model is still downloading or getting ready.
    case notReady
}

/// Apple's on-device model, owned by this feature because tests cannot run it.
///
/// The live implementation wraps the FoundationModels framework. Tests pass a double through
/// `FakeServices.override`, and scenarios, self-tests and benchmarks get ``SimulatedOnDeviceModel``.
nonisolated protocol OnDeviceModelService: Sendable {
    /// Whether the model can answer now. Reads the framework's availability, which never prompts.
    @concurrent func status() async -> OnDeviceStatus

    /// The answer to `prompt` under `instructions`, as text added piece by piece. Cancelling the
    /// consumer stops the generation. Throws ``AIFailure``.
    func respond(instructions: String, prompt: String, maximumTokens: Int?) -> AsyncThrowingStream<String, any Error>
}

/// The on-device model for each kind of run.
nonisolated enum OnDeviceModelKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any OnDeviceModelService {
        AppleOnDeviceModel()
    }

    static func isolated(_ context: FeatureContext) -> any OnDeviceModelService {
        SimulatedOnDeviceModel()
    }
}

/// The on-device model as a provider. It keeps no conversation of its own: each answer gets the
/// conversation so far written into its prompt.
nonisolated struct OnDeviceProvider: ModelProvider {
    let model: any OnDeviceModelService

    var kind: ProviderKind { .onDevice }
    var modelName: String { Strings.Providers.onDeviceModel }
    var host: String? { nil }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let pieces = model.respond(
            instructions: request.system, prompt: Self.prompt(for: request.normalizedTurns),
            maximumTokens: request.length.onDeviceMaximumTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in pieces where !piece.isEmpty {
                        continuation.yield(.text(piece))
                    }
                    try Task.checkCancellation()
                    continuation.yield(.finished(.complete))
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: error is CancellationError || error is AIFailure
                            ? error : Strings.Failures.onDeviceFailed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The prompt: the last question, after the earlier turns when there are some.
    static func prompt(for turns: [ModelTurn]) -> String {
        guard let last = turns.last else { return "" }
        let earlier = turns.dropLast()
        guard !earlier.isEmpty else { return last.text }
        let history = earlier.map { turn in
            (turn.role == .user ? Prompts.historyUser : Prompts.historyAssistant) + turn.text
        }
        return Prompts.historyIntro + "\n\n" + history.joined(separator: "\n\n") + "\n\n" + Prompts.historyQuestion
            + "\n\n" + last.text
    }
}
