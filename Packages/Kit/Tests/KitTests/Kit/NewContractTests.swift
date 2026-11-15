import Foundation
import Kit
import KitTesting
import Testing

/// A conversion that shows a loading row until its rates arrive, then the answer.
final class RatesSketch: Feature, InstantProvider {
    static let manifest = FeatureManifest(id: "rates-sketch", name: "Rates", icon: .symbol("dollarsign"))

    let namespace = "rates-sketch"
    let signal = ChangeSignal()
    var rate: Double?

    init(context: FeatureContext) {}

    var liveProviders: [LiveProvider] { [.instant(self)] }
    var answersChanged: ChangeSignal? { signal }

    func answer(for query: String) -> InstantAnswer? {
        guard query.hasPrefix("5 usd") else { return nil }
        let title = rate.map { String(format: "%.2f EUR", 5 * $0) } ?? "Loading Rates"
        return InstantAnswer(
            rows: [Row(id: ItemID(namespace, "5-usd-eur"), title: title, memory: .never)], claimsTop: true)
    }

    func actions(for row: Row) -> [Action] {
        [Action.copy(row.title, title: "Copy Answer")]
    }

    /// Rates arrive, as a download would deliver them, and the provider says its answer changed.
    func ratesArrived(_ rate: Double) {
        self.rate = rate
        signal.send()
    }
}

/// A feature off by default that onboarding suggests.
final class SuggestedSketch: Feature {
    static let manifest = FeatureManifest(
        id: "suggested-sketch", name: "Suggested", icon: .symbol("star"), isEnabledByDefault: false,
        isSuggestedInOnboarding: true)

    init(context: FeatureContext) {}
}

@Suite("New contracts", .timeLimit(.minutes(1)))
struct NewContractTests {
    @Test func anInstantProviderSaysItsAnswerChanged() async throws {
        let harness = FeatureHarness(RatesSketch.self)
        #expect(harness.instantAnswers(for: "5 usd in eur").first?.rows.first?.title == "Loading Rates")
        let arrival = Task { @MainActor in harness.feature.ratesArrived(0.92) }
        let answers = try await harness.instantAnswersAfterChange(for: "5 usd in eur")
        await arrival.value
        #expect(answers.first?.rows.first?.title == "4.60 EUR")
        #expect(harness.issues.isEmpty)
    }

    @Test func aChangeSentBeforeTheWaitIsNotMissed() async throws {
        let harness = FeatureHarness(RatesSketch.self)
        _ = harness.instantAnswers(for: "5 usd")
        harness.feature.ratesArrived(1)
        let answers = try await harness.instantAnswersAfterChange(for: "5 usd")
        #expect(answers.first?.rows.first?.title == "5.00 EUR")
    }

    @Test func waitingForAnAnswerChangeNeedsASignal() async {
        let harness = FeatureHarness(CalculatorSketch.self)
        #expect(CalculatorSketch(context: FakeServices().context(featureID: "calculator")).answersChanged == nil)
        await #expect(throws: HarnessError.self) { _ = try await harness.instantAnswersAfterChange(for: "1+1") }
    }

    @Test func onboardingSuggestsOnlyAFeatureThatIsOffByDefault() {
        #expect(!FeatureManifest(id: "plain", name: "Plain", icon: .symbol("circle")).isSuggestedInOnboarding)
        #expect(FeatureValidator.validate(SuggestedSketch.manifest).isEmpty)
        let onAnyway = FeatureManifest(
            id: "loud", name: "Loud", icon: .symbol("speaker"), isSuggestedInOnboarding: true)
        #expect(FeatureValidator.validate(onAnyway).map(\.message).contains { $0.contains("isSuggestedInOnboarding") })
    }

    @Test func fileNamesShowOnOneLineInStoredOrder() {
        #expect(DisplayText.fileName("report.pdf") == "report.pdf")
        #expect(DisplayText.fileName("two\nlines.txt") == "two lines.txt")
        #expect(DisplayText.fileName("tab\there\u{2028}sep") == "tab here sep")
        let override = "invoice\u{202E}fdp.app"
        let shown = DisplayText.fileName(override)
        #expect(shown == "invoice\u{FFFD}fdp.app")
        #expect(shown.utf16.count == override.utf16.count)
        #expect(DisplayText.oneLine("a\u{2066}b\u{2069}c") == "a\u{FFFD}b\u{FFFD}c")
        #expect(DisplayText.oneLine("Café 🇫🇷 שלום") == "Café 🇫🇷 שלום")
    }

    @Test func aFileNameThatShowsNothingOrRunsLongStillReads() {
        #expect(DisplayText.fileName(" ") == DisplayText.untitled)
        #expect(DisplayText.fileName("\u{200B}\u{2060}") == "Untitled Item")
        #expect(DisplayText.fileName("") == "Untitled Item")
        let long = String(repeating: "a", count: 80)
        let cut = DisplayText.fileName(long)
        #expect(cut.count == 60 && cut.hasSuffix("…"))
        #expect(DisplayText.fileName(long, limit: 10) == String(repeating: "a", count: 9) + "…")
        #expect(DisplayText.fileName("abc", limit: 0) == "a…")
    }

    @Test func theTrashQuestionNamesTheFileSafely() throws {
        let url = URL(filePath: "/tmp/sample/invoice\u{202E}fdp.app\nnext")
        let question = try #require(Action.moveToTrash([url]).confirmation?.title)
        #expect(question == "Move “invoice\u{FFFD}fdp.app next” to the Trash?")
        let two = [URL(filePath: "/tmp/sample/a.txt"), URL(filePath: "/tmp/sample/b.txt")]
        #expect(Action.moveToTrash(two).confirmation?.title == "Move 2 items to the Trash?")
    }
}
