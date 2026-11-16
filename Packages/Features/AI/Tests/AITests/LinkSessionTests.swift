import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

/// Runs in a panel session a deep link opened, or handed off from a run a link started, count as
/// started by a link whatever their launch says. Found in review: AI checked only for the deep
/// link launch, so Tab after a search link sent the link's text to the provider at once, and a
/// text command in such a session read the selection of the page that fired the link.
@Suite("AI in a session a link opened", .timeLimit(.minutes(1)))
@MainActor
struct LinkSessionTests {
    @Test func askAIByTabShowsTheFormAndSendsNothing() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.harness.inLinkSession = true
        try await ai.harness.pressTab("text a web page typed")
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.initialValues.text("text") == "text a web page typed")
        #expect(ai.fakes.http.requests.isEmpty)
    }

    @Test func aTextCommandReadsNoSelection() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.harness.inLinkSession = true
        ai.fakes.selection.selection = .text("text the page selected")
        try await ai.harness.run("improve-writing")
        guard case .form = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.fakes.http.requests.isEmpty)
    }

    @Test func aHandOffToACustomCommandReadsNothing() async throws {
        let ai = try await AIHarness()
        try await ai.feature.saveCustomCommands([
            CustomCommand(
                id: "custom.mix-0000eeee", title: "Mix", prompt: "Use {clipboard} and {selection}",
                replacesSelection: true)
        ])
        ai.harness.inLinkSession = true
        ai.fakes.selection.selection = .text("selected")
        _ = ai.fakes.pasteboard.simulateCopy("copied")
        try await ai.harness.run("custom.mix-0000eeee", launch: .command)
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(!form.initialValues.text("text").contains("copied"))
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.onDevice.requests.isEmpty)
    }

    @Test func outsideALinkSessionTabAsksAtOnce() async throws {
        let ai = try await AIHarness()
        try await ai.harness.pressTab("my own question")
        #expect(ai.harness.page?.page.isForm == false)
        #expect(ai.onDevice.requests.count == 1)
    }
}

extension Page {
    fileprivate var isForm: Bool {
        if case .form = self { return true }
        return false
    }
}
