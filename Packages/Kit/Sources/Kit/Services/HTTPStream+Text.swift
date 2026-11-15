import Foundation

/// One server-sent event, as AI providers stream answers.
public struct ServerSentEvent: Hashable, Sendable {
    /// The `event:` field, when the server named the event.
    public var event: String?
    /// The `data:` lines, joined with line breaks.
    public var data: String
    /// The `id:` field, when present.
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Collects the fields of server-sent events line by line and hands back each event when the blank
/// line that ends it arrives. Comments and unknown fields are skipped.
public struct ServerSentEventParser: Sendable {
    private var event: String?
    private var data: [String] = []
    private var id: String?

    public init() {}

    /// The event this line ends, or nil.
    public mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { (event, data, id) = (nil, [], nil) }
            return data.isEmpty ? nil : ServerSentEvent(event: event, data: data.joined(separator: "\n"), id: id)
        }
        guard !line.hasPrefix(":") else { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            (field, value) = (line[...], "")
        }
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        case "id": id = String(value)
        default: break
        }
        return nil
    }
}

extension HTTPStream {
    /// The body as lines of text, decoded off the main thread. It throws `CancellationError` when the
    /// consuming task is cancelled, and cancelling it cancels the request.
    public var lines: AsyncThrowingStream<String, any Error> {
        let body = body
        return AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = LineSplitter()
                do {
                    for try await chunk in body {
                        for line in splitter.append(chunk) { continuation.yield(line) }
                    }
                    if let last = splitter.finish() { continuation.yield(last) }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The body as server-sent events, parsed off the main thread.
    public var serverSentEvents: AsyncThrowingStream<ServerSentEvent, any Error> {
        let lines = lines
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ServerSentEventParser()
                do {
                    for try await line in lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    if let event = parser.feed("") { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole body. Throws `CancellationError` when the calling task is cancelled.
    public func data() async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        try Task.checkCancellation()
        return data
    }
}
