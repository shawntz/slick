import Foundation
import Kit

/// Any server that speaks the OpenAI chat completions format: a hosted service, or a local server
/// such as Ollama or LM Studio.
///
/// The request is `POST <base address>/chat/completions` with `stream: true`. The key, when there is
/// one, goes in an `Authorization: Bearer` header. The answer arrives as server-sent events whose
/// data is a chunk with `choices[0].delta.content`, and ends with `data: [DONE]`.
nonisolated struct OpenAICompatibleProvider: ModelProvider {
    /// How long the stream may stay silent. A local server may load the model before its first word.
    static let idleTimeout = Duration.seconds(180)

    let http: any HTTPService
    let baseAddress: URL
    let apiKey: String?
    let model: String

    var kind: ProviderKind { .openAICompatible }
    var modelName: String { model }
    var host: String? { Self.hostName(of: baseAddress) }

    /// The address requests go to: the base address with `chat/completions` added, unless the user
    /// gave the full address.
    var endpoint: URL {
        let path = baseAddress.path(percentEncoded: false)
        if path.hasSuffix("/chat/completions") || path.hasSuffix("/chat/completions/") { return baseAddress }
        return baseAddress.appending(path: "chat/completions", directoryHint: .notDirectory)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, any Error> {
        let http = http
        let host = Self.hostName(of: baseAddress)
        let httpRequest = Result { try makeHTTPRequest(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await http.stream(try httpRequest.get())
                    if let target = response.refusedRedirect {
                        throw Strings.Failures.redirectRefused(from: host, to: target, checksAddress: true)
                    }
                    guard (200..<300).contains(response.status) else {
                        let body = try await response.boundedText()
                        throw HTTPFailures.compatible(
                            status: response.status, headers: response.headers, body: body, host: host)
                    }
                    var decoder = ChatCompletionsStreamDecoder(host: host)
                    for try await event in response.serverSentEvents {
                        for output in try decoder.feed(event) { continuation.yield(output) }
                        if decoder.isFinished { break }
                    }
                    try Task.checkCancellation()
                    for output in try decoder.finish() { continuation.yield(output) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPFailures.transport(error, host: host))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The HTTP request for a conversation. The system prompt goes first as a system message.
    func makeHTTPRequest(_ request: ModelRequest) throws -> HTTPRequest {
        var headers = ["content-type": "application/json", "accept": "text/event-stream"]
        if let apiKey, !apiKey.isEmpty { headers["authorization"] = "Bearer " + apiKey }
        var messages: [Message] = []
        if !request.system.isEmpty { messages.append(Message(role: "system", content: request.system)) }
        messages += request.normalizedTurns.map { Message(role: $0.role.rawValue, content: $0.text) }
        let body = Body(model: model, messages: messages, stream: true, maxTokens: request.length.serverMaximumTokens)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return HTTPRequest(
            endpoint, method: "POST", headers: headers, body: try encoder.encode(body), timeout: Self.idleTimeout)
    }

    /// A base address the user typed, or nil when it is not an `http` or `https` address with a host.
    /// An address with a user name or password in it is refused: the key has its own field, in the
    /// Keychain.
    static func parseAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: false), !host.isEmpty, url.user == nil, url.password == nil,
            url.fragment == nil
        else {
            return nil
        }
        return url
    }

    /// The host as people read it, such as "localhost" or "api.example.com".
    static func hostName(of url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    /// True for a plain `http` address on another machine, where what is sent crosses the network
    /// unencrypted. This Mac's own addresses stay on this Mac.
    static func isUnencrypted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = hostName(of: url).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let loopback = host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
        return !loopback
    }

    struct Body: Encodable {
        var model: String
        var messages: [Message]
        var stream: Bool
        var maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case maxTokens = "max_tokens"
        }
    }

    struct Message: Encodable {
        var role: String
        var content: String
    }
}

/// Reads a chat completions event stream. Each event's data is a chunk; the answer's text is in
/// `choices[0].delta.content`, and `finish_reason` says why it stopped. `[DONE]` ends the stream.
/// Some servers end after a finish reason without `[DONE]`, which counts as finished too. A stream
/// with neither was cut off.
nonisolated struct ChatCompletionsStreamDecoder {
    private let host: String
    private var stopReason = StopReason.complete
    private var sawFinishReason = false
    private(set) var isFinished = false

    init(host: String) {
        self.host = host
    }

    /// What one event adds to the answer. Throws ``AIFailure`` for an error chunk.
    mutating func feed(_ event: ServerSentEvent) throws -> [ModelEvent] {
        guard !isFinished else { return [] }
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" {
            isFinished = true
            return [.finished(stopReason)]
        }
        guard let chunk = try? Self.decoder.decode(Chunk.self, from: Data(data.utf8)) else { return [] }
        if chunk.error != nil {
            throw Strings.Failures.serverProblem(host, detail: HTTPFailures.decodeError(data).message)
        }
        var events: [ModelEvent] = []
        for choice in chunk.choices ?? [] where (choice.index ?? 0) == 0 {
            if let text = choice.delta?.content, !text.isEmpty { events.append(.text(text)) }
            if let reason = choice.finishReason {
                sawFinishReason = true
                switch reason {
                case "length": stopReason = .lengthLimit
                case "content_filter": stopReason = .refused
                default: stopReason = .complete
                }
            }
        }
        return events
    }

    /// Checks the stream ended properly.
    func finish() throws -> [ModelEvent] {
        if isFinished { return [] }
        if sawFinishReason { return [.finished(stopReason)] }
        throw Strings.Failures.cutOff
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Chunk: Decodable {
        var choices: [Choice]?
        var error: ErrorMarker?
    }

    /// Present when the chunk is an error. Its contents are read separately, as they vary.
    private struct ErrorMarker: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private struct Choice: Decodable {
        var index: Int?
        var delta: Delta?
        var finishReason: String?
    }

    private struct Delta: Decodable {
        var content: String?
    }
}
