import Foundation
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import Root

/// A query that a provider takes over and that an instant answer claims the top for, as a snippet
/// keyword behind the prefix ">" is both a shell command and a snippet. The user chose the keyword,
/// so the answer that claims the top wins and the takeover does not happen.
@Suite("A takeover against an answer that claims the top", .timeLimit(.minutes(1)))
struct TakeoverClaimTests {
    private func fixture() async -> (RootFixture, RateAnswers) {
        let fixture = await RootFixture.ready()
        let feature = fixture.directory.register(RatesFeature.self, fakes: fixture.fakes)
        await fixture.settle()
        return (fixture, feature.rates)
    }

    @Test func anAnswerThatClaimsTheTopBeatsATakeover() async throws {
        let (fixture, rates) = await fixture()
        rates.answers["/date"] = [RateAnswers.row("date", "Today's Date")]
        let root = fixture.root
        _ = root.begin()
        let snapshot = root.update(query: "/date")
        let first = snapshot.sections.first
        #expect(first?.kind == .answers)
        #expect(snapshot.rows.first?.title == "Today's Date")
        let takenOver = root.pendingProviders.contains { $0.takesOver }
        #expect(!takenOver)
        root.end()
        await fixture.shutdown()
    }

    @Test func anAnswerThatDoesNotClaimTheTopLeavesTheTakeover() async throws {
        let (fixture, rates) = await fixture()
        rates.claimsTop = false
        rates.answers["/date"] = [RateAnswers.row("date", "Today's Date")]
        let root = fixture.root
        _ = root.begin()
        let snapshot = root.update(query: "/date")
        #expect(snapshot.sections.isEmpty)
        #expect(root.pendingProviders.map(\.takesOver) == [true])
        root.end()
        await fixture.shutdown()
    }
}
