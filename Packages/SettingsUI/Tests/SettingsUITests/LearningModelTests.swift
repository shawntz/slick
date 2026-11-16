import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct LearningModelTests {
    private func filledBed() -> TestBed {
        let bed = TestBed()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = ItemID("app", "com.example.notes")
        let terminal = ItemID("app", "com.example.terminal")
        bed.learning.items = [
            LearnedItem(id: notes, title: "Example Notes", useCount: 12, lastUsed: day),
            LearnedItem(
                id: terminal, title: "Example Terminal", useCount: 30, lastUsed: day.addingTimeInterval(-86_400)),
            LearnedItem(id: TestBed.open, title: "Open Sample", useCount: 3, lastUsed: day),
        ]
        bed.learning.learnedQueries = [
            LearnedQuery(query: "te", items: [.init(id: terminal, title: "Example Terminal", weight: 2.4)]),
            LearnedQuery(query: "no", items: [.init(id: notes, title: "Example Notes", weight: 1.3)]),
            LearnedQuery(query: "op", items: [.init(id: TestBed.open, title: "Open Sample", weight: 0.6)]),
        ]
        return bed
    }

    @Test func loadsSummaryItemsAndQueries() async {
        let bed = filledBed()
        let model = LearningModel(context: bed.context())
        await model.load()
        #expect(model.summary.eventCount == 45)
        #expect(model.summaryText == "45 runs across 3 items and 3 searches")
        #expect(model.sinceText != nil)
        #expect(model.topItems.map(\.title) == ["Example Terminal", "Example Notes", "Open Sample"])
        #expect(model.queries.map(\.query) == ["te", "no", "op"])
        // A command's icon comes from its feature when the inspector has none.
        #expect(model.icon(for: model.topItems[2]) == SampleFeature.manifest.icon)
    }

    @Test func emptyHistory() async {
        let bed = TestBed()
        let model = LearningModel(context: bed.context())
        await model.load()
        #expect(model.summaryText == "Nothing learned yet")
        #expect(model.sinceText == nil)
    }

    @Test func filtersQueries() async {
        let bed = filledBed()
        let model = LearningModel(context: bed.context())
        await model.load()
        model.filter = "t"
        #expect(await eventually { model.queries.map(\.query) == ["te"] })
    }

    @Test func forgetsOneQueryOrOneItem() async {
        let bed = filledBed()
        let model = LearningModel(context: bed.context())
        await model.load()
        await model.forget(query: "no")
        #expect(bed.learning.forgottenQueries == ["no"])
        #expect(model.queries.map(\.query) == ["te", "op"])
        await model.forget(item: ItemID("app", "com.example.terminal"))
        #expect(model.topItems.map(\.title) == ["Example Notes", "Open Sample"])
        #expect(model.queries.map(\.query) == ["op"])
    }

    @Test func pauses() {
        let bed = TestBed()
        let model = LearningModel(context: bed.context())
        #expect(!model.isPaused)
        model.isPaused = true
        #expect(bed.learning.isPaused)
        #expect(bed.general[HostSettings.learningPaused])
    }

    @Test func eraseAsksFirst() async {
        let bed = filledBed()
        let context = bed.context()
        let model = LearningModel(context: context)
        await model.load()

        let declined = Task { await model.eraseAll() }
        #expect(await eventually { context.confirmations.pending != nil })
        #expect(context.confirmations.pending?.confirmation.isDestructive == true)
        context.confirmations.answer(false)
        await declined.value
        #expect(bed.learning.eraseCount == 0)

        let accepted = Task { await model.eraseAll() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(true)
        await accepted.value
        #expect(bed.learning.eraseCount == 1)
        #expect(model.topItems.isEmpty)
        #expect(model.summaryText == "Nothing learned yet")
    }

    @Test func marksTheItemThatRanksFirst() async {
        let bed = TestBed()
        let terminal = ItemID("app", "com.example.terminal")
        let term = ItemID("app", "com.example.term")
        bed.learning.learnedQueries = [
            LearnedQuery(
                query: "term",
                items: [
                    .init(id: term, title: "Example Term", weight: 1.5),
                    .init(id: terminal, title: "Example Terminal", weight: 1.3, holdsBand: true),
                ]),
            LearnedQuery(query: "no", items: [.init(id: term, title: "Example Term", weight: 0.6)]),
        ]
        let model = LearningModel(context: bed.context())
        await model.load()
        let first = model.queries.first { $0.query == "term" }
        #expect(first.flatMap(model.bandHolder(of:))?.title == "Example Terminal", "not the strongest, the holder")
        let second = model.queries.first { $0.query == "no" }
        #expect(second.flatMap(model.bandHolder(of:)) == nil)
    }

    @Test func listsSwitchedOffSuggestionsAndTurnsOneOn() async {
        let bed = TestBed()
        bed.learning.learnedTriggers = [
            LearnedTrigger(
                featureID: "sample", triggerID: "meeting-soon", acceptance: 0.03, impressions: 24, taken: 1,
                isOff: true),
            LearnedTrigger(
                featureID: "gone", triggerID: "new_download", acceptance: 0.02, impressions: 30, taken: 0, isOff: true),
            LearnedTrigger(
                featureID: "sample", triggerID: "focus", acceptance: 0.7, impressions: 4, taken: 3, isOff: false),
        ]
        let context = bed.context()
        let model = LearningModel(context: context)
        await model.load()
        #expect(model.switchedOffTriggers.map(\.id) == ["sample.meeting-soon", "gone.new_download"])
        let meeting = model.switchedOffTriggers[0]
        #expect(model.featureName(of: meeting) == SampleFeature.manifest.name)
        #expect(model.triggerTitle(meeting) == "Meeting soon")
        #expect(model.triggerDetail(meeting) == "From Sample Tools. You picked it 1 of 24 times.")
        #expect(model.featureName(of: model.switchedOffTriggers[1]) == "gone", "an unknown feature shows its ID")
        #expect(model.triggerTitle(model.switchedOffTriggers[1]) == "New download")

        await model.turnOn(meeting)
        #expect(bed.learning.resetTriggers == ["sample.meeting-soon"])
        #expect(model.switchedOffTriggers.map(\.id) == ["gone.new_download"])
        #expect(context.toasts.current?.toast.title == "Suggestions from \(SampleFeature.manifest.name) are back on")
    }

    @Test func aFailedEraseShowsAToast() async {
        let bed = filledBed()
        bed.learning.eraseFailure = ActionFailure("The history is locked")
        let context = bed.context()
        let model = LearningModel(context: context)
        let erase = Task { await model.eraseAll() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(true)
        await erase.value
        #expect(context.toasts.current?.toast.title == "The history is locked")
        #expect(model.topItems.count == 3)
    }
}
