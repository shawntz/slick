import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

/// The Tab command a snapshot carries, the learned band flag, and suggestion triggers in the
/// learning inspector.
@MainActor @Suite("Learning and Tab", .timeLimit(.minutes(1)))
struct LearningAndTabTests {
    @Test func aSnapshotCarriesNoTabCommandUntilRootFillsIt() {
        #expect(RootSnapshot().tabCommand == nil)
        let source = FakeRootSource(rows: [Row(id: ItemID("app", "com.example.notes"), title: "Notes")])
        #expect(source.update(query: "no").tabCommand == nil)
        let search = ItemID.command(feature: "web", command: "search")
        source.tabCommand = search
        #expect(source.update(query: "not").tabCommand == search)
        #expect(source.begin().tabCommand == nil, "the empty state has nothing to run")
    }

    @Test func aFavoredItemDoesNotHoldTheBandUnlessSaid() {
        let id = ItemID("app", "com.example.terminal")
        #expect(!LearnedQuery.Favored(id: id, title: "Terminal", weight: 2).holdsBand)
        #expect(LearnedQuery.Favored(id: id, title: "Terminal", weight: 1.2, holdsBand: true).holdsBand)
    }

    @Test func anInspectorWithoutTriggersListsNone() async {
        let inspector = MinimalInspector()
        #expect(await inspector.triggers().isEmpty)
        await inspector.resetTrigger(featureID: "calendar", triggerID: "meeting-soon")
    }

    @Test func theFakeResetsATriggerAndSignals() async {
        let off = LearnedTrigger(
            featureID: "calendar", triggerID: "meeting-soon", acceptance: 0.03, impressions: 24, taken: 0, isOff: true)
        let on = LearnedTrigger(
            featureID: "files", triggerID: "new-download", acceptance: 0.6, impressions: 5, taken: 3, isOff: false)
        let inspector = FakeLearningInspector(triggers: [off, on])
        #expect(off.id == "calendar.meeting-soon")
        #expect(await inspector.triggers().filter(\.isOff).map(\.id) == ["calendar.meeting-soon"])
        let generation = inspector.changes.generation
        await inspector.resetTrigger(featureID: "calendar", triggerID: "meeting-soon")
        #expect(inspector.resetTriggers == ["calendar.meeting-soon"])
        #expect(await inspector.triggers().allSatisfy { !$0.isOff })
        #expect(await inspector.triggers().first?.impressions == 0)
        #expect(await inspector.triggers().last == on)
        #expect(inspector.changes.generation == generation + 1)
    }
}

/// An inspector written before triggers existed, which still compiles.
@MainActor private final class MinimalInspector: LearningInspector {
    let changes = ChangeSignal()
    var isPaused: Bool { false }
    func setPaused(_ paused: Bool) {}
    func summary() async -> LearningSummary { .empty }
    func topItems(limit: Int) async -> [LearnedItem] { [] }
    func queries(matching text: String, limit: Int) async -> [LearnedQuery] { [] }
    func forget(item id: ItemID) async {}
    func forget(query: String) async {}
    func eraseAll() async throws {}
}
