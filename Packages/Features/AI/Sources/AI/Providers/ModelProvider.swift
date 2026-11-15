import Foundation
import Kit

/// A model the feature can ask: Apple's on-device model, the Anthropic API or an OpenAI-compatible
/// server. Each one streams an answer as ``ModelEvent``s.
///
/// `stream(_:)` returns at once. The work runs in a task off the main thread, which the stream
/// cancels when its consumer stops reading, so a cancelled answer also cancels its request.
nonisolated protocol ModelProvider: Sendable {
    /// Which kind of provider this is.
    var kind: ProviderKind { get }
    /// The model's name as people know it, for the detail page.
    var modelName: String { get }
    /// Where requests go, such as "api.anthropic.com". Nil when nothing leaves the Mac.
    var host: String? { get }

    /// The answer to the conversation's last user turn. Ends with ``ModelEvent/finished(_:)`` when the
    /// model finished. Throws ``AIFailure`` with words for the user, or `CancellationError`.
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error>
}

/// One turn of a conversation as a provider sends it.
nonisolated struct ModelTurn: Hashable, Sendable {
    enum Role: String, Hashable, Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
    /// Anthropic thinking blocks that came with this answer, sent back as the API asks.
    var replay: [AnthropicReplayBlock]

    init(_ role: Role, _ text: String, replay: [AnthropicReplayBlock] = []) {
        self.role = role
        self.text = text
        self.replay = replay
    }
}

/// What a provider is asked: a system prompt, the conversation so far and a length limit.
nonisolated struct ModelRequest: Hashable, Sendable {
    var system: String
    var turns: [ModelTurn]
    var length: ResponseLength

    /// The turns as every API accepts them: no empty answers, no two turns in a row from the same
    /// side, and a user turn first. An answer stopped before its first word leaves two questions in
    /// a row, which are sent as one.
    var normalizedTurns: [ModelTurn] {
        var result: [ModelTurn] = []
        for turn in turns {
            if turn.role == .assistant && turn.text.isEmpty { continue }
            if result.isEmpty && turn.role == .assistant { continue }
            if let last = result.last, last.role == turn.role {
                result[result.count - 1] = ModelTurn(last.role, last.text + "\n\n" + turn.text)
            } else {
                result.append(turn)
            }
        }
        return result
    }
}

/// One step of a streamed answer.
nonisolated enum ModelEvent: Hashable, Sendable {
    /// More text of the answer.
    case text(String)
    /// A finished Anthropic thinking block to send back with this answer in the next turn.
    case replay(AnthropicReplayBlock)
    /// The served model switched mid-answer after a decline, so thinking from this answer must not be
    /// sent back.
    case discardReplay
    /// The model finished, and why.
    case finished(StopReason)
}

/// Why a model stopped.
nonisolated enum StopReason: Hashable, Sendable {
    /// It said all it had to say.
    case complete
    /// It reached the response length limit.
    case lengthLimit
    /// It declined to answer.
    case refused
}

/// A thinking block from the Anthropic API, kept so the next turn can send it back unchanged.
/// With the default display the thinking text is empty and only the signature matters.
nonisolated struct AnthropicReplayBlock: Codable, Hashable, Sendable {
    /// "thinking" or "redacted_thinking".
    var type: String
    var thinking: String?
    var signature: String?
    var data: String?

    static func thinking(_ text: String, signature: String) -> AnthropicReplayBlock {
        AnthropicReplayBlock(type: "thinking", thinking: text, signature: signature)
    }

    static func redacted(_ data: String) -> AnthropicReplayBlock {
        AnthropicReplayBlock(type: "redacted_thinking", data: data)
    }
}

/// A failure with words for the user: a title and a sentence that says what to do.
nonisolated struct AIFailure: LocalizedError, Codable, Hashable, Sendable, CustomStringConvertible {
    var title: String
    var message: String

    init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    var errorDescription: String? { title }
    var failureReason: String? { message }
    var description: String { "\(title): \(message)" }
}
