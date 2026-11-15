import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import AI

/// A test double for Apple's on-device model: a status, scripted pieces of an answer or a failure,
/// and a record of what it was asked.
nonisolated final class FakeOnDeviceModel: OnDeviceModelService {
    struct Request: Hashable, Sendable {
        var instructions: String
        var prompt: String
        var maximumTokens: Int?
    }

    private struct State {
        var status = OnDeviceStatus.available
        var pieces = ["On-device ", "answer."]
        var failure: AIFailure?
        var requests: [Request] = []
        var statusReads = 0
    }

    private let state = Mutex(State())

    var status: OnDeviceStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var pieces: [String] {
        get { state.withLock { $0.pieces } }
        set { state.withLock { $0.pieces = newValue } }
    }

    var failure: AIFailure? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var statusReads: Int { state.withLock { $0.statusReads } }

    @concurrent func status() async -> OnDeviceStatus {
        state.withLock { state in
            state.statusReads += 1
            return state.status
        }
    }

    func respond(instructions: String, prompt: String, maximumTokens: Int?) -> AsyncThrowingStream<String, any Error> {
        let (pieces, failure) = state.withLock { state in
            state.requests.append(Request(instructions: instructions, prompt: prompt, maximumTokens: maximumTokens))
            return (state.pieces, state.failure)
        }
        return AsyncThrowingStream { continuation in
            for piece in pieces { continuation.yield(piece) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }
}

/// An HTTP service that streams a body from raw byte chunks, so a test can split a character or a
/// line anywhere. FakeHTTP takes chunks as strings, which cannot split a character.
nonisolated struct ByteChunkHTTP: HTTPService {
    let status: Int
    var headers: [String: String] = [:]
    let chunks: [Data]

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: status, body: chunks.reduce(Data(), +))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let chunks = chunks
        return HTTPStream(
            status: status, headers: headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            })
    }
}

/// Server-sent events written by hand from the Messages API's documented stream format.
nonisolated enum AnthropicSSE {
    static func event(_ name: String, _ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    static func messageStart(model: String = "claude-opus-5-5") -> String {
        event(
            "message_start",
            [
                "type": "message_start",
                "message": [
                    "id": "msg_test", "type": "message", "role": "assistant", "model": model, "content": [Any](),
                    "stop_reason": NSNull(), "stop_sequence": NSNull(),
                    "usage": ["input_tokens": 12, "output_tokens": 1],
                ],
            ])
    }

    static func thinkingBlock(index: Int, signature: String) -> [String] {
        [
            event(
                "content_block_start",
                [
                    "type": "content_block_start", "index": index,
                    "content_block": ["type": "thinking", "thinking": "", "signature": ""],
                ]),
            event(
                "content_block_delta",
                [
                    "type": "content_block_delta", "index": index,
                    "delta": ["type": "signature_delta", "signature": signature],
                ]),
            event("content_block_stop", ["type": "content_block_stop", "index": index]),
        ]
    }

    static func textStart(index: Int) -> String {
        event(
            "content_block_start",
            ["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]])
    }

    static func textDelta(_ text: String, index: Int) -> String {
        event(
            "content_block_delta",
            ["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": text]])
    }

    static func blockStop(index: Int) -> String {
        event("content_block_stop", ["type": "content_block_stop", "index": index])
    }

    static let ping = "event: ping\ndata: {\"type\": \"ping\"}\n\n"

    static func messageEnd(stopReason: String = "end_turn") -> [String] {
        [
            event(
                "message_delta",
                [
                    "type": "message_delta", "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
                    "usage": ["output_tokens": 15],
                ]),
            event("message_stop", ["type": "message_stop"]),
        ]
    }

    static func error(type: String, message: String) -> String {
        event("error", ["type": "error", "error": ["type": type, "message": message]])
    }

    /// A whole answer, one event per chunk: message start, an optional thinking block, a ping, the
    /// text in pieces, and the end.
    static func answer(_ pieces: [String], stopReason: String = "end_turn", signature: String? = nil) -> [String] {
        var chunks = [messageStart()]
        var index = 0
        if let signature {
            chunks += thinkingBlock(index: 0, signature: signature)
            index = 1
        }
        chunks.append(textStart(index: index))
        chunks.append(ping)
        chunks += pieces.map { textDelta($0, index: index) }
        chunks.append(blockStop(index: index))
        chunks += messageEnd(stopReason: stopReason)
        return chunks
    }

    /// An error response body, as the API sends with a status outside 200 to 299.
    static func errorBody(type: String, message: String) -> String {
        "{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"\(message)\"},\"request_id\":\"req_test\"}"
    }
}

/// Server-sent events in the OpenAI chat completions stream format.
nonisolated enum CompletionSSE {
    static func chunk(content: String?, finishReason: String? = nil, role: String? = nil) -> String {
        var delta: [String: Any] = [:]
        if let content { delta["content"] = content }
        if let role { delta["role"] = role }
        let choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finishReason ?? NSNull()]
        let object: [String: Any] = [
            "id": "chatcmpl-test", "object": "chat.completion.chunk", "created": 1_763_000_000, "model": "test-model",
            "choices": [choice],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    static let done = "data: [DONE]\n\n"

    static func answer(_ pieces: [String], finishReason: String = "stop") -> [String] {
        [chunk(content: "", role: "assistant")] + pieces.map { chunk(content: $0) }
            + [chunk(content: nil, finishReason: finishReason), done]
    }
}

/// Builds the feature over fakes with a fake on-device model.
@MainActor
struct AIHarness {
    static let anthropicKey = "sk-ant-test-0000"
    static let serverURL = URL(string: "http://localhost:11434/v1/chat/completions") ?? URL(filePath: "/")

    let harness: FeatureHarness<AIFeature>
    let onDevice: FakeOnDeviceModel

    var fakes: FakeServices { harness.fakes }
    var feature: AIFeature { harness.feature }
    var settings: FeatureSettings { harness.context.settings }

    init(
        provider: ProviderKind = .onDevice, onDeviceStatus: OnDeviceStatus = .available,
        permissions: PermissionStatus = .granted, activate: Bool = true
    ) async throws {
        let fakes = FakeServices(permissions: permissions)
        let onDevice = FakeOnDeviceModel()
        onDevice.status = onDeviceStatus
        fakes.override(OnDeviceModelKey.self, with: onDevice)
        harness = FeatureHarness(AIFeature.self, fakes: fakes)
        self.onDevice = onDevice
        switch provider {
        case .onDevice:
            break
        case .anthropic:
            try await useAnthropic()
        case .openAICompatible:
            useServer()
        }
        if activate {
            await harness.activate()
            await feature.waitUntilLoaded()
            try await harness.settle()
        }
    }

    func useAnthropic(model: AnthropicModel = .opus) async throws {
        settings[AISettings.provider] = .anthropic
        settings[AISettings.anthropicModel] = model
        try await fakes.secrets.setSecret(Self.anthropicKey, for: "ai." + AISecrets.anthropicKey)
    }

    func useServer(address: String = "http://localhost:11434/v1", model: String = "test-model") {
        settings[AISettings.provider] = .openAICompatible
        settings[AISettings.serverAddress] = address
        settings[AISettings.serverModel] = model
    }

    func stubAnthropic(_ chunks: [String], status: Int = 200, keepsOpen: Bool = false) {
        fakes.http.stub(AnthropicProvider.endpoint, status: status, chunks: chunks, keepsOpen: keepsOpen)
    }

    func stubServer(_ chunks: [String], status: Int = 200) {
        fakes.http.stub(Self.serverURL, status: status, chunks: chunks)
    }

    /// The text the top detail page shows.
    var shownText: String {
        if case .markdown(let text) = harness.detail?.body { return text }
        return ""
    }

    /// The answer page's source, when the top page is one.
    var session: AnswerSession? {
        guard case .detail(let page) = harness.page?.page else { return nil }
        return page.source as? AnswerSession
    }

    /// The JSON body of the request at an index, as plain objects.
    func requestBody(_ index: Int = 0) throws -> [String: Any] {
        let request = try #require(fakes.http.requests.dropFirst(index).first)
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// The messages a request sent, as role and content pairs. Content is text, or the types of its
    /// blocks joined by commas when it is a list.
    func sentMessages(_ index: Int = 0) throws -> [[String]] {
        let messages = try #require(try requestBody(index)["messages"] as? [[String: Any]])
        return messages.map { message in
            let role = message["role"] as? String ?? ""
            if let text = message["content"] as? String { return [role, text] }
            let blocks = message["content"] as? [[String: Any]] ?? []
            return [role, blocks.compactMap { $0["type"] as? String }.joined(separator: ",")]
        }
    }
}

/// Waits for something a background task does without a signal of its own, such as a cancelled
/// request reaching the fake HTTP service. Gives up after two seconds.
func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never became true")
}
