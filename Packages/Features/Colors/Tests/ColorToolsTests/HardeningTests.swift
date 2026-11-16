import Foundation
import Kit
import KitTesting
import Synchronization
import Testing

@testable import ColorTools

/// What the reviews of earlier features found, checked here before review: repeated starts, links,
/// stale actions, scale and the way back to the history.
@Suite("Hardening", .timeLimit(.minutes(1)))
struct HardeningTests {
    @Test func aSecondPickWhileTheSamplerShowsIsDropped() async throws {
        let sampler = HoldingSampler()
        let fakes = FakeServices()
        fakes.override(ColorSamplerKey.self, with: sampler)
        let harness = FeatureHarness(ColorsFeature.self, fakes: fakes)
        await harness.activate()
        await harness.feature.waitUntilReady()
        let started = sampler.started
        let first = Task { try await harness.run("pick") }
        for await _ in started { break }
        let second = try await harness.run("pick")
        #expect(second.kind == .keepOpen)
        #expect(harness.droppedRuns == ["command.pick"])
        sampler.release()
        _ = try await first.value
        #expect(sampler.shown == 1)
        #expect(harness.fakes.pasteboard.copiedTexts == ["#663399"])
    }

    @Test func aDeepLinkNeverShowsTheSampler() async throws {
        let sampler = SimulatedColorSampler()
        let harness = await readyHarness(sampler: sampler)
        let outcome = try await harness.run("pick", launch: .deeplink)
        #expect(outcome.kind == .close(hud: nil))
        #expect(sampler.count == 0)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
    }

    @Test func actionsMadeBeforeADeleteChangeNothing() async throws {
        let harness = await readyHarness()
        await harness.feature.history.add(try color("#663399"), source: .picked)
        try await harness.run("history")
        let actions = harness.actions()
        await harness.feature.history.clear()
        harness.throwsActionErrors = false
        let pin = try #require(actions.first { $0.id == "pin" })
        try await harness.perform(pin, row: harness.selectedRow)
        let rename = try #require(actions.first { $0.id == "rename" })
        try await harness.perform(rename, row: harness.selectedRow)
        let delete = try #require(actions.first { $0.id == "delete" })
        try await harness.perform(delete, row: harness.selectedRow)
        #expect(harness.toasts.map(\.title) == ["Color Not Found", "Color Not Found", "Color Not Found"])
        #expect(harness.feature.history.entries.isEmpty, "nothing came back")
    }

    @Test func aRenameFormSubmittedAfterTheColorWentChangesNothing() async throws {
        let harness = await readyHarness()
        await harness.feature.history.add(try color("#663399"), source: .picked)
        try await harness.run("history")
        try await harness.perform("rename")
        await harness.feature.history.clear()
        harness.throwsActionErrors = false
        try harness.fill("name", text: "Brand Purple")
        try await harness.submit()
        #expect(harness.toasts.last?.title == "Color Not Found")
        #expect(harness.feature.history.entries.isEmpty)
    }

    @Test func aTypedColorOpensTheHistory() async throws {
        let harness = await readyHarness()
        let row = try #require(harness.answerRow("#663399"))
        try await harness.performRoot("run.cmd:colors.history", on: row)
        #expect(harness.commandRuns == [CommandRun(id: .command(feature: "colors", command: "history"))])
        guard case .list(let list) = harness.page?.page else {
            Issue.record("the history did not open")
            return
        }
        #expect(list.title == "Color History")
        harness.unavailableCommands = [.command(feature: "colors", command: "history")]
        #expect(!harness.rootActions(for: row).contains { $0.id == "run.cmd:colors.history" })
    }

    @Test func aLargeHistoryKeepsOneEntryPerColorAndListsPinsFirst() async throws {
        let fakes = FakeServices()
        fakes.settings.set(.int(10_000), for: "colors.historyLimit")
        let now = fakes.clock.now
        let entries = (0..<5_000).map { index in
            ColorEntry(
                color: ColorValue(bytes: index % 256, index / 256, 0), isPinned: index == 4_999,
                date: now.addingTimeInterval(-Double(index)), source: .picked)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(ColorHistoryFile(entries: entries)), as: UTF8.self)
        try writeHistory(text, in: fakes)
        let harness = await readyHarness(fakes: fakes)
        #expect(harness.feature.history.entries.count == 5_000)

        await harness.feature.history.add(ColorValue(bytes: 5, 0, 0), source: .typed)
        let kept = harness.feature.history.entries
        #expect(kept.count == 5_000, "the same color again moves, it is not added twice")
        #expect(kept.first?.color == ColorValue(bytes: 5, 0, 0) && kept.first?.source == .typed)
        let sections = HistoryList.build(kept, formatter: ColorFormatter(), format: .hex, clock: harness.fakes.clock)
        #expect(sections.first?.title == "Pinned" && sections.first?.rows.count == 1)
        #expect(sections.reduce(0) { $0 + $1.rows.count } == 5_000)
    }

    @Test func historyRowsHaveVisibleOneLineTitles() async throws {
        let harness = await readyHarness()
        let names = ["\u{202E}fdp.exe", "Tab\there", "  ", "Line\u{2028}Separator", String(repeating: "W", count: 200)]
        for (index, name) in names.enumerated() {
            let entry = try #require(
                await harness.feature.history.add(ColorValue(bytes: index, 0, 0), source: .picked))
            await harness.feature.history.rename(entry.id, to: name)
        }
        try await harness.run("history")
        for row in harness.rows {
            #expect(!row.title.isEmpty && row.title.count <= 60)
            #expect(!row.title.unicodeScalars.contains { $0.properties.generalCategory == .control })
            #expect(!row.title.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
            #expect(!row.title.unicodeScalars.contains { $0 == "\u{2028}" })
        }
        #expect(harness.rows.contains { $0.title == "#020000" }, "a blank name shows the hex value")
        #expect(harness.issues.isEmpty)
    }
}

/// A sampler that holds the first pick open until the test releases it, so a test can start a
/// second pick while the first one shows. It returns Rebecca Purple.
nonisolated final class HoldingSampler: ColorSampler {
    private let gate = AsyncStream<Void>.makeStream()
    private let opened = AsyncStream<Void>.makeStream()
    private let count = Mutex(0)

    /// Yields once when the sampler shows.
    var started: AsyncStream<Void> { opened.stream }

    var shown: Int { count.withLock { $0 } }

    func release() {
        gate.continuation.yield()
    }

    func sample() async throws -> PickedColor? {
        count.withLock { $0 += 1 }
        opened.continuation.yield()
        for await _ in gate.stream { break }
        return SimulatedColorSampler.sample
    }
}
