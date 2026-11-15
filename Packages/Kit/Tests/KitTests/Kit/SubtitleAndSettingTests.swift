import Foundation
import Kit
import KitTesting
import Testing

/// Subtitle colors on rows, live subtitles that fetch off the main thread, and settings fakes that
/// stay quiet for writes that change nothing.
@Suite("Subtitles and settings", .timeLimit(.minutes(1)))
struct SubtitleAndSettingTests {
    @Test func aSubtitleColorSurvivesEncoding() throws {
        let row = Row(
            id: ItemID("script", "uptime"), title: "Uptime", subtitle: "failed", subtitleColor: .red)
        let decoded = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(row))
        #expect(decoded.subtitleColor == .red)
        #expect(decoded == row)

        let plain = Row(id: ItemID("script", "date"), title: "Date")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("subtitleColor"), "a row without a color encodes as before")
    }

    @Test func aBackgroundSubtitleFetchesOffTheMainThread() async {
        let subtitle = LiveSubtitle.background(every: .seconds(30)) {
            LiveSubtitle.Value(threadName(), color: .green)
        }
        #expect(subtitle.backgroundFetch != nil)
        #expect(await subtitle.value() == LiveSubtitle.Value("background", color: .green))
        #expect(await subtitle.fetch() == LiveSubtitle.Value("background", color: .green))
    }

    @MainActor @Test func aMainActorSubtitleStillFetchesOnTheMainActor() async {
        let subtitle = LiveSubtitle(every: .seconds(30)) {
            LiveSubtitle.Value(threadName())
        }
        #expect(subtitle.backgroundFetch == nil)
        #expect(await subtitle.value() == "main")
    }

    @Test func aWriteThatChangesNothingSendsNoChange() async {
        let settings = FakeSettings()
        let log = NameLog()
        let changes = settings.changes(for: ["demo.mode"])
        let watcher = Task {
            for await name in changes { await log.add(name) }
        }
        settings.set(.string("dark"), for: "demo.mode")
        await settings.settle()
        settings.set(.string("dark"), for: "demo.mode")
        await settings.settle()
        settings.set(nil, for: "demo.mode")
        await settings.settle()
        settings.set(nil, for: "demo.mode")
        await settings.settle()
        #expect(await log.names == ["demo.mode", "demo.mode"], "only the first write and the removal changed")
        watcher.cancel()
    }
}

/// "main" on the main thread, "background" elsewhere. Synchronous, so async code may call it.
private nonisolated func threadName() -> String {
    Thread.isMainThread ? "main" : "background"
}

/// Names a change stream delivered, in order.
private actor NameLog {
    private(set) var names: [String] = []

    func add(_ name: String) {
        names.append(name)
    }
}
