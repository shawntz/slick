import CoreGraphics
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@Suite(.timeLimit(.minutes(1))) struct PlatformFakeTests {
    @Test func iconsAreSolidSquaresAndHeldIconsArriveLate() throws {
        let icons = FakeIconProvider()
        let size = IconSize(points: 28, scale: 2)
        let app = Icon.app(bundleID: "com.example.notes")
        let image = try #require(icons.image(for: app, size: size, isDark: false))
        #expect(image.width == 56 && image.height == 56)
        let pixel = try #require(Self.firstPixel(of: image))
        let expected = FakeIconProvider.color(for: app)
        #expect(abs(Double(pixel.red) / 255 - expected.red) < 0.01)
        #expect(abs(Double(pixel.blue) / 255 - expected.blue) < 0.01)

        let late = Icon.favicon(domain: "example.com")
        icons.holdBack(late)
        #expect(icons.image(for: late, size: size, isDark: true) == nil)
        let generation = icons.changes.generation
        icons.deliverHeldIcons()
        #expect(icons.changes.generation == generation + 1)
        #expect(icons.image(for: late, size: size, isDark: true) != nil)

        let adaptive = Icon.adaptive(light: .symbol("sun.max"), dark: .symbol("moon"))
        _ = icons.image(for: adaptive, size: size, isDark: true)
        #expect(icons.lookups.last == .symbol("moon"))
        icons.prepare([app, late], size: size)
        #expect(icons.prepared == [[app, late]])
        #expect(IconSize(points: 16, scale: 1.5).pixels == 24)
    }

    @Test func systemContextStreamsChangesAndSessionStarts() async throws {
        let system = FakeSystemContext()
        #expect(system.current().frontmostBundleID == "com.example.editor")
        var contexts = system.changes().makeAsyncIterator()
        var sessions = system.sessionStarts().makeAsyncIterator()

        system.simulateChange { $0.onBattery = true }
        system.simulate(system.current())
        system.simulateChange { $0.audioRoute = .bluetooth }
        let first = await contexts.next()
        let second = await contexts.next()
        #expect(first?.onBattery == true && first?.audioRoute == .builtIn)
        #expect(second?.audioRoute == .bluetooth)

        let wake = Date(timeIntervalSinceReferenceDate: 800_000_000)
        system.simulateSessionStart(at: wake)
        #expect(await sessions.next() == wake)
        #expect(system.current().audioRoute == .bluetooth)
        #expect(system.listenerCount == 2)
    }

    @Test func settleWaitsForAConsumerLoop() async throws {
        let system = FakeSystemContext()
        let seen = SeenDisplays()
        let stream = system.changes()
        let task = Task {
            for await context in stream { await seen.add(context.displayCount) }
        }
        system.simulateChange { $0.displayCount = 2 }
        system.simulateChange { $0.displayCount = 3 }
        await system.settle()
        #expect(await seen.counts == [2, 3])
        task.cancel()
    }

    @Test func loginItemRecordsRequestsAndFailures() throws {
        let login = FakeLoginItem()
        try login.setEnabled(true)
        #expect(login.isEnabled)
        login.failure = CancellationError()
        #expect(throws: CancellationError.self) { try login.setEnabled(false) }
        #expect(login.isEnabled)
        #expect(login.requests == [true, false])
    }

    @Test func learningInspectorSummarisesAndForgets() async throws {
        let settings = FakeSettings()
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let notes = ItemID("app", "com.example.notes")
        let calendar = ItemID("app", "com.example.calendar")
        let inspector = FakeLearningInspector(
            items: [
                LearnedItem(id: notes, title: "Notes", useCount: 3, lastUsed: day),
                LearnedItem(id: calendar, title: "Calendar", useCount: 5, lastUsed: day.addingTimeInterval(-60)),
            ],
            queries: [
                LearnedQuery(query: "no", items: [.init(id: notes, title: "Notes", weight: 1.4)]),
                LearnedQuery(query: "cal", items: [.init(id: calendar, title: "Calendar", weight: 2)]),
            ],
            settings: settings)

        inspector.setPaused(true)
        #expect(inspector.isPaused)
        #expect(HostSettings.settings(settings)[HostSettings.learningPaused])
        let summary = await inspector.summary()
        #expect(summary.eventCount == 8 && summary.itemCount == 2 && summary.queryCount == 2)
        #expect(summary.firstEvent == day.addingTimeInterval(-60))
        #expect(await inspector.topItems(limit: 1).map(\.id) == [calendar])
        #expect(await inspector.queries(matching: "", limit: 10).map(\.query) == ["cal", "no"])
        #expect(await inspector.queries(matching: "N", limit: 10).map(\.query) == ["no"])

        await inspector.forget(item: notes)
        #expect(inspector.items.map(\.id) == [calendar])
        #expect(inspector.learnedQueries.map(\.query) == ["cal"])
        inspector.eraseFailure = CancellationError()
        await #expect(throws: CancellationError.self) { try await inspector.eraseAll() }
        inspector.eraseFailure = nil
        try await inspector.eraseAll()
        #expect(await inspector.summary() == .empty)
        #expect(inspector.forgottenItems == [notes])
    }

    private static func firstPixel(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        return (bytes[0], bytes[1], bytes[2])
    }
}

private actor SeenDisplays {
    var counts: [Int] = []

    func add(_ count: Int) {
        counts.append(count)
    }
}
