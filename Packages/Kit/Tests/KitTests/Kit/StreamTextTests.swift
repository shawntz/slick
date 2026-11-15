import Foundation
import Kit
import KitTesting
import Testing

@Suite("Streamed text")
struct StreamTextTests {
    @Test func aCharacterSplitAcrossChunksArrivesWhole() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("café ✓".utf8)
        // "é" is two bytes and "✓" three; cut inside both.
        let text =
            decoder.decode(Data(bytes[0..<4])) + decoder.decode(Data(bytes[4..<7]))
            + decoder.decode(Data(bytes[7...])) + decoder.finish()
        #expect(text == "café ✓")
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func linesSplitOnAnyLineEnding() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("one\r\ntw".utf8)) == ["one"])
        #expect(splitter.append(Data("o\nthr".utf8)) == ["two"])
        #expect(splitter.finish() == "thr")
        #expect(splitter.finish() == nil)
    }

    @Test func serverSentEventsCollectTheirFields() {
        var parser = ServerSentEventParser()
        let lines = [": keep-alive", "event: delta", "id: 7", "data: {\"a\":", "data: 1}", "", "data: [DONE]", ""]
        let events = lines.compactMap { parser.feed($0) }
        #expect(
            events == [ServerSentEvent(event: "delta", data: "{\"a\":\n1}", id: "7"), ServerSentEvent(data: "[DONE]")])
    }

    @Test func anHTTPStreamReadsAsEvents() async throws {
        let http = FakeHTTP()
        let url = try #require(URL(string: "https://ai.example.test/stream"))
        http.stub(url, chunks: ["data: Hel", "lo\n\nda", "ta: wörld\n\n"])
        let response = try await http.stream(HTTPRequest(url))
        var data: [String] = []
        for try await event in response.serverSentEvents { data.append(event.data) }
        #expect(data == ["Hello", "wörld"])
    }

    @Test func processTextNeverSplitsACharacter() async throws {
        let processes = FakeProcesses()
        let bytes = Array("é\n".utf8)
        processes.stub(
            "tool", output: FakeProcessOutput(events: [.stdout(Data(bytes[0..<1])), .stdout(Data(bytes[1...]))]))
        var events: [ProcessTextEvent] = []
        for try await event in processes.textStream(ProcessRequest(executable: URL(filePath: "/tmp/tool"))) {
            events.append(event)
        }
        #expect(events == [.stdout("é\n"), .exit(0)])
    }

    @Test func aCancelledRunThrowsInsteadOfReturningCutOutput() async {
        let processes = FakeProcesses()
        processes.stub("tool", output: FakeProcessOutput(events: [.stdout(Data("partial".utf8))], keepsRunning: true))
        let run = Task { try await processes.run(ProcessRequest(executable: URL(filePath: "/tmp/tool"))) }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }
}
