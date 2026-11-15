import CoreBridge
import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// Suggestion triggers through root search: when they are asked, which rows Thompson sampling
/// inserts, what the user's response teaches, and what is kept.
@Suite struct TriggerTests {
    /// A fixture whose meeting trigger offers one meeting from the start.
    static func offering(_ names: [String], storage: RootStoragePaths = .inMemory) async -> RootFixture {
        let now = FakeClock().now
        return await RootFixture.ready(
            storage: storage, signals: true,
            offered: { feature in
                feature.meetings.offered = names.map { MeetingTrigger.meeting($0, at: now) }
            })
    }

    /// One panel session: open, wait, then close without running anything.
    static func ignore(_ fixture: RootFixture, for seconds: Int = 2) async {
        _ = fixture.root.begin()
        fixture.clock.advance(by: .seconds(seconds))
        fixture.root.end()
        await fixture.settle()
    }

    @Test func triggersAreAskedOnStartContextChangeSignalIntervalAndWakeButNeverOnTheHotkey() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let meetings = try fixture.signalsFeature().meetings
        #expect(meetings.asks.count == 1)

        _ = fixture.root.begin()
        fixture.root.end()
        await fixture.settle()
        #expect(meetings.asks.count == 1)

        fixture.system.simulateChange { $0.onBattery = true }
        await fixture.settle()
        #expect(meetings.asks.count == 2)

        meetings.signal.send()
        await fixture.settle()
        #expect(meetings.asks.count == 3)

        fixture.system.simulateSessionStart(at: fixture.clock.now)
        await fixture.settle()
        #expect(meetings.asks.count == 4)

        for _ in 0..<50 { await Task.yield() }
        fixture.clock.advance(by: .seconds(60))
        await fixture.settle()
        #expect(meetings.asks.count == 5)
        await fixture.shutdown()
    }

    @Test func aTriggerRowLeadsSuggestedAndRoutesToItsTrigger() async throws {
        let fixture = await Self.offering(["standup"])
        let empty = fixture.root.begin()
        let suggested = try #require(empty.sections.first)
        #expect(suggested.kind == .suggested)
        let row = try #require(suggested.rows.first)
        #expect(row.title == "Join Standup")
        #expect(fixture.root.actions(for: row).map(\.title) == ["Join Meeting"])
        #expect(fixture.root.featureID(for: row) == "signals")
        #expect(fixture.root.row(for: row.id)?.title == "Join Standup")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aTriggerWithoutItsPermissionIsSkippedUntilGranted() async throws {
        let fakes = FakeServices()
        fakes.permissions.set(.calendars, to: .denied)
        let now = fakes.clock.now
        let fixture = await RootFixture.ready(
            fakes: fakes, signals: true,
            offered: { $0.meetings.offered = [MeetingTrigger.meeting("standup", at: now)] })
        let meetings = try fixture.signalsFeature().meetings
        #expect(meetings.asks.isEmpty)
        #expect(!fixture.root.begin().rows.contains { $0.title == "Join Standup" })
        fixture.root.end()

        fakes.permissions.set(.calendars, to: .granted)
        fixture.system.simulateChange { $0.displayCount = 2 }
        await fixture.settle()
        #expect(meetings.asks.count == 1)
        #expect(fixture.root.begin().rows.first?.title == "Join Standup")
        fixture.root.end()
        await fixture.settle()

        fakes.permissions.set(.calendars, to: .denied)
        await fixture.settle()
        // A revoked permission hides the rows at the next preparation, without asking.
        fixture.preferences.setFavorites([fixture.apps.id("Music")])
        await fixture.settle()
        #expect(!fixture.root.begin().rows.contains { $0.title == "Join Standup" })
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func atMostOneTriggerRowAndTwoWhenOneIsImminent() async throws {
        let fixture = await Self.offering(["standup", "review", "retro"])
        let meetings = try fixture.signalsFeature().meetings
        let one = fixture.root.begin()
        fixture.root.end()
        #expect(one.rows.filter { $0.id.namespace == "meeting" }.count == 1)

        let now = fixture.clock.now
        meetings.offered = [
            MeetingTrigger.meeting("standup", at: now),
            MeetingTrigger.meeting("review", at: now, imminent: true),
            MeetingTrigger.meeting("retro", at: now),
        ]
        meetings.signal.send()
        await fixture.settle()
        let two = fixture.root.begin()
        fixture.root.end()
        let rows = two.rows.filter { $0.id.namespace == "meeting" }
        #expect(rows.count == 2)
        #expect(rows.contains { $0.title == "Join Review" })
        await fixture.shutdown()
    }

    @Test func aSuggestionIgnoredThreeTimesStopsShowing() async throws {
        let fixture = await Self.offering(["standup"])
        for _ in 0..<3 {
            #expect(fixture.root.begin().rows.first?.title == "Join Standup")
            fixture.root.end()
            await Self.ignore(fixture)
        }
        #expect(!fixture.root.begin().rows.contains { $0.title == "Join Standup" })
        fixture.root.end()
        let stats = try #require(fixture.root.learning.state.triggers["signals.meeting-soon"])
        #expect(stats.rejects > stats.priorRejects)
        await fixture.shutdown()
    }

    @Test func typingWithinASecondIsNotAnIgnoreAndRunningIsAnAccept() async throws {
        let fixture = await Self.offering(["standup"])
        for _ in 0..<4 {
            _ = fixture.root.begin()
            _ = fixture.root.update(query: "cal")
            fixture.clock.advance(by: .seconds(5))
            fixture.root.end()
            await fixture.settle()
        }
        #expect(fixture.root.learning.state.ignored.isEmpty)
        let shown = fixture.root.begin()
        let row = try #require(shown.rows.first { $0.title == "Join Standup" })
        fixture.root.didRun(row, launch: .suggestion)
        fixture.root.end()
        await fixture.settle()
        let stats = try #require(fixture.root.learning.state.triggers["signals.meeting-soon"])
        #expect(stats.accepts == stats.priorAccepts + 1)
        #expect(stats.taken == 1)
        #expect(fixture.root.triggerStates.first?.taken == 1)
        await fixture.shutdown()
    }

    @Test func aThrowingTriggerKeepsItsSuggestions() async throws {
        let fixture = await Self.offering(["standup"])
        let meetings = try fixture.signalsFeature().meetings
        meetings.failure = ExampleFailure()
        meetings.signal.send()
        await fixture.settle()
        #expect(meetings.asks.count == 2)
        #expect(fixture.root.begin().rows.first?.title == "Join Standup")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func aTypeThatSwitchedOffIsNotAskedAndShowsNothing() async throws {
        let fixture = await Self.offering(["standup"])
        let meetings = try fixture.signalsFeature().meetings
        fixture.root.learning.update { state in
            var stats = TriggerStats(prior: meetings.prior, now: fixture.clock.now)
            stats.isOff = true
            state.triggers["signals.meeting-soon"] = stats
        }
        meetings.signal.send()
        await fixture.settle()
        #expect(meetings.asks.count == 1)
        fixture.preferences.setFavorites([fixture.apps.id("Music")])
        await fixture.settle()
        #expect(!fixture.root.begin().rows.contains { $0.title == "Join Standup" })
        fixture.root.end()
        #expect(fixture.root.triggerStates.first?.isOff == true)

        fixture.root.resetTrigger(featureID: "signals", triggerID: "meeting-soon")
        await fixture.settle()
        #expect(meetings.asks.count == 2)
        #expect(fixture.root.begin().rows.first?.title == "Join Standup")
        fixture.root.end()
        await fixture.shutdown()
    }

    @Test func theFrontmostAppAndFavoritesAreNotRepeatedAsTriggerRows() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let meetings = try fixture.signalsFeature().meetings
        let now = fixture.clock.now
        let editor = Row(id: ItemID("app", "com.example.editor"), title: "Editor")
        let preview = Row(id: fixture.apps.id("Preview"), title: "Preview")
        meetings.offered = [
            Suggestion(id: "front", row: editor, urgency: .constant(1), expires: now.addingTimeInterval(600)),
            Suggestion(id: "fav", row: preview, urgency: .constant(1), expires: now.addingTimeInterval(600)),
        ]
        fixture.preferences.setFavorites([preview.id])
        meetings.signal.send()
        await fixture.settle()
        let empty = fixture.root.begin()
        fixture.root.end()
        #expect(empty.section(containing: preview.id)?.kind == .favorites)
        #expect(!empty.rows.contains { $0.id == editor.id })
        await fixture.shutdown()
    }

    @Test func pausedLearningTeachesTheTriggersNothing() async throws {
        let fixture = await Self.offering(["standup"])
        fixture.general[HostSettings.learningPaused] = true
        await fixture.settle()
        await Self.ignore(fixture)
        await Self.ignore(fixture)
        #expect(fixture.root.learning.state.triggers.isEmpty)
        #expect(fixture.root.learning.state.ignored.isEmpty)
        await fixture.shutdown()
    }

    @Test func triggerLearningSurvivesARelaunch() async throws {
        let folder = TemporaryFolder()
        let storage = RootStoragePaths(directory: folder.url)
        let first = await Self.offering(["standup"], storage: storage)
        await Self.ignore(first)
        await first.root.flush()
        await first.shutdown()

        let second = await Self.offering(["standup"], storage: storage)
        let stats = try #require(second.root.learning.state.triggers["signals.meeting-soon"])
        #expect(stats.impressions == 1)
        #expect(second.root.learning.state.ignored["signals.meeting-soon|event-standup"]?.count == 1)
        await second.shutdown()
    }

    @Test func expiredSuggestionsLeaveWithoutAnAsk() async throws {
        let fixture = await RootFixture.ready(signals: true)
        let meetings = try fixture.signalsFeature().meetings
        let now = fixture.clock.now
        meetings.offered = [
            Suggestion(
                id: "short", row: Row(id: ItemID("meeting", "short"), title: "Join Short", memory: .never),
                urgency: .constant(1), expires: now.addingTimeInterval(30))
        ]
        meetings.signal.send()
        await fixture.settle()
        #expect(fixture.root.begin().rows.first?.title == "Join Short")
        fixture.root.end()
        await fixture.settle()
        for _ in 0..<50 { await Task.yield() }
        fixture.clock.advance(by: .seconds(31))
        await fixture.settle()
        #expect(!fixture.root.begin().rows.contains { $0.title == "Join Short" })
        fixture.root.end()
        await fixture.shutdown()
    }

    // MARK: Pure parts

    @Test func betaDrawsHaveTheRightMean() {
        var generator = SplitMix64(seed: 7)
        for (a, b) in [(4.0, 1.0), (1.0, 3.0), (0.5, 0.5), (30.0, 70.0)] {
            var sum = 0.0
            let n = 4_000
            for _ in 0..<n {
                let draw = BetaSampler.sample(a, b, using: &generator)
                #expect(draw >= 0 && draw <= 1)
                sum += draw
            }
            #expect(abs(sum / Double(n) - a / (a + b)) < 0.02)
        }
    }

    @Test func theChooserKeepsOneSlotOrTwoForAnImminentSuggestion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func candidate(_ name: String, draw: Double, urgency: Double = 1, imminent: Bool = false) -> TriggerCandidate {
            TriggerCandidate(
                typeKey: "t",
                suggestion: MeetingTrigger.meeting(name, at: now, urgency: .constant(urgency), imminent: imminent),
                draw: draw)
        }
        #expect(TriggerChooser.choose([], at: now).isEmpty)
        #expect(TriggerChooser.choose([candidate("a", draw: 0.1)], at: now).isEmpty)
        #expect(TriggerChooser.choose([candidate("a", draw: 0.9, urgency: 0.1)], at: now).isEmpty)
        let one = TriggerChooser.choose([candidate("a", draw: 0.5), candidate("b", draw: 0.9)], at: now)
        #expect(one.map(\.suggestion.id) == ["event-b"])
        let two = TriggerChooser.choose(
            [candidate("a", draw: 0.9), candidate("b", draw: 0.8), candidate("c", draw: 0.3, imminent: true)], at: now)
        #expect(two.map(\.suggestion.id) == ["event-a", "event-c"])
        let same = TriggerChooser.choose(
            [candidate("a", draw: 0.9, imminent: true), candidate("a", draw: 0.8, imminent: true)], at: now)
        #expect(same.count == 1)
    }

    @Test func statsDecayTowardThePriorAndSwitchOffWhenAcceptanceStaysLow() {
        let start = Date(timeIntervalSince1970: 0)
        var stats = TriggerStats(prior: AcceptancePrior(accepts: 1, rejects: 3), now: start)
        for _ in 0..<19 { stats.ignore(at: start) }
        #expect(!stats.isOff)
        stats.ignore(at: start)
        #expect(stats.impressions == 20)
        #expect(stats.isOff)

        var learned = TriggerStats(prior: AcceptancePrior(accepts: 2, rejects: 2), now: start)
        learned.accept(at: start)
        learned.accept(at: start)
        let month = start.addingTimeInterval(TriggerStats.halfLife)
        let decayed = learned.decayed(to: month)
        #expect(abs(decayed.accepts - 3) < 1e-9)
        #expect(abs(decayed.rejects - 2) < 1e-9)

        var adopted = learned
        adopted.adopt(AcceptancePrior(accepts: 5, rejects: 2))
        #expect(adopted.accepts == 7)
        #expect(TriggerStats.sane(AcceptancePrior(accepts: -1, rejects: .nan)).accepts > 0)
    }
}
