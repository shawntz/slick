import Foundation
import Kit

/// Anthropic's Messages API, streamed as server-sent events through Kit's HTTP service.
///
/// The request is `POST /v1/messages` with `stream: true`, the key in `x-api-key` and the API version
/// in `anthropic-version`. Thinking is left to the model's default, which every current model runs,
/// and no sampling parameters are sent: the API version refuses them. For the models that take them,
/// server-side fallbacks are on, so a declined request is answered by the model the API picks for
/// the decline, inside the same stream.
nonisolated struct AnthropicProvider: ModelProvider {
    static let host = "api.anthropic.com"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages") ?? URL(filePath: "/")
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// How long the stream may stay silent. The API sends pings while the model thinks.
    static let idleTimeout = Duration.seconds(120)

    let http: any HTTPService
    let apiKey: String
    let model: AnthropicModel

    var kind: ProviderKind { .anthropic }
    var modelName: String { Strings.Settings.modelTitle(model) }
    var host: String? { Self.host }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let http = http
        let model = model
        let httpRequest = Result { try makeHTTPRequest(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await http.stream(try httpRequest.get())
                    if let target = response.refusedRedirect {
                        throw Strings.Failures.redirectRefused(from: Self.host, to: target, checksAddress: false)
                    }
                    guard (200..<300).contains(response.status) else {
                        let body = try await response.boundedText()
                        throw HTTPFailures.anthropic(
                            status: response.status, headers: response.headers, body: body,
                            model: Strings.Settings.modelTitle(model))
                    }
                    var decoder = AnthropicStreamDecoder(modelName: Strings.Settings.modelTitle(model))
                    for try await event in response.serverSentEvents {
                        for output in try decoder.feed(event) { continuation.yield(output) }
                    }
                    try Task.checkCancellation()
                    for output in try decoder.finish() { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPFailures.transport(error, host: Self.host))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The HTTP request for a conversation.
    func makeHTTPRequest(_ request: ModelRequest) throws -> HTTPRequest {
        var headers = [
            "content-type": "application/json",
            "accept": "text/event-stream",
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
        ]
        if model.takesFallbacks { headers["anthropic-beta"] = Self.fallbackBeta }
        let body = Body(
            model: model.rawValue,
            maxTokens: request.length.anthropicMaximumTokens,
            stream: true,
            system: request.system.isEmpty ? nil : request.system,
            messages: request.normalizedTurns.map(Message.init),
            fallbacks: model.takesFallbacks ? "default" : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HTTPRequest(
            Self.endpoint, method: "POST", headers: headers, body: try encoder.encode(body), timeout: Self.idleTimeout)
    }

    // MARK: - Request body

    struct Body: Encodable {
        var model: String
        var maxTokens: Int
        var stream: Bool
        var system: String?
        var messages: [Message]
        var fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case stream
            case system
            case messages
            case fallbacks
        }
    }

    /// One message. A user turn is a string. An answer that came with thinking blocks sends them back
    /// first, unchanged, then its text.
    struct Message: Encodable {
        var role: String
        var text: String
        var replay: [AnthropicReplayBlock]

        init(_ turn: ModelTurn) {
            role = turn.role.rawValue
            text = turn.text
            replay = turn.role == .assistant ? turn.replay : []
        }

        enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if replay.isEmpty {
                try container.encode(text, forKey: .content)
            } else {
                var blocks = container.nestedUnkeyedContainer(forKey: .content)
                for block in replay { try blocks.encode(block) }
                try blocks.encode(TextBlock(text: text))
            }
        }
    }

    struct TextBlock: Encodable {
        var type = "text"
        var text: String
    }
}

/// Reads the Messages API's event stream: `message_start`, then for each content block a
/// `content_block_start`, its deltas and a `content_block_stop`, then `message_delta` with the stop
/// reason and `message_stop`. `ping` events keep the connection open; an `error` event ends the
/// answer. Unknown events and block types are skipped, as the API asks.
///
/// An answer that ends without `message_stop` was cut off: ``finish()`` says so. An event whose JSON
/// does not parse is skipped, which is what a stream that stops mid-event leaves at its end.
nonisolated struct AnthropicStreamDecoder {
    private enum OpenBlock {
        case thinking(text: String, signature: String)
        case redacted(String)
        case other
    }

    private let modelName: String
    private var blocks: [Int: OpenBlock] = [:]
    private var stopReason = StopReason.complete
    private(set) var isFinished = false

    init(modelName: String) {
        self.modelName = modelName
    }

    /// What one event adds to the answer. Throws ``AIFailure`` for an `error` event.
    mutating func feed(_ event: ServerSentEvent) throws -> [ModelEvent] {
        guard let payload = try? Self.decoder.decode(Payload.self, from: Data(event.data.utf8)) else { return [] }
        switch payload.type {
        case "content_block_start":
            return start(payload)
        case "content_block_delta":
            return delta(payload)
        case "content_block_stop":
            return stop(payload.index)
        case "message_delta":
            switch payload.delta?.stopReason {
            case "max_tokens": stopReason = .lengthLimit
            case "refusal": stopReason = .refused
            default: break
            }
            return []
        case "message_stop":
            isFinished = true
            return [.finished(stopReason)]
        case "error":
            throw HTTPFailures.anthropic(
                errorType: payload.error?.type, message: payload.error?.message, status: nil, retryAfter: nil,
                model: modelName)
        default:
            return []
        }
    }

    /// Checks the stream ended properly. Throws the cut-off failure when `message_stop` never came.
    func finish() throws -> [ModelEvent] {
        guard isFinished else { throw Strings.Failures.cutOff }
        return []
    }

    private mutating func start(_ payload: Payload) -> [ModelEvent] {
        guard let index = payload.index, let block = payload.contentBlock else { return [] }
        switch block.type {
        case "text":
            blocks[index] = .other
            if let text = block.text, !text.isEmpty { return [.text(text)] }
        case "thinking":
            blocks[index] = .thinking(text: block.thinking ?? "", signature: block.signature ?? "")
        case "redacted_thinking":
            blocks[index] = .redacted(block.data ?? "")
        case "fallback":
            blocks[index] = .other
            return [.discardReplay]
        default:
            blocks[index] = .other
        }
        return []
    }

    private mutating func delta(_ payload: Payload) -> [ModelEvent] {
        guard let delta = payload.delta else { return [] }
        switch delta.type {
        case "text_delta":
            if let text = delta.text, !text.isEmpty { return [.text(text)] }
        case "thinking_delta":
            if let index = payload.index, case .thinking(let text, let signature) = blocks[index] {
                blocks[index] = .thinking(text: text + (delta.thinking ?? ""), signature: signature)
            }
        case "signature_delta":
            if let index = payload.index, case .thinking(let text, let signature) = blocks[index] {
                blocks[index] = .thinking(text: text, signature: signature + (delta.signature ?? ""))
            }
        default:
            break
        }
        return []
    }

    private mutating func stop(_ index: Int?) -> [ModelEvent] {
        guard let index, let block = blocks.removeValue(forKey: index) else { return [] }
        switch block {
        case .thinking(let text, let signature) where !signature.isEmpty:
            return [.replay(.thinking(text, signature: signature))]
        case .redacted(let data) where !data.isEmpty:
            return [.replay(.redacted(data))]
        default:
            return []
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Payload: Decodable {
        var type: String
        var index: Int?
        var contentBlock: Block?
        var delta: Delta?
        var error: APIError?
    }

    private struct Block: Decodable {
        var type: String
        var text: String?
        var thinking: String?
        var signature: String?
        var data: String?
    }

    private struct Delta: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var signature: String?
        var stopReason: String?
    }

    private struct APIError: Decodable {
        var type: String?
        var message: String?
    }
}
