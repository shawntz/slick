import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("Ask AI", .timeLimit(.minutes(1)))
@MainActor
struct AskTests {
    @Test func declaresTabFallbackAndArgument() async throws {
        let ai = try await AIHarness()
        let ask = try ai.harness.command("ask")
        #expect(ask.title == "Ask AI")
        #expect(ask.takesRootQueryOnTab)
        #expect(ask.fallback?.title("why is the sky blue") == "Ask AI about \u{201C}why is the sky blue\u{201D}")
        #expect(ask.fallback?.startsOn == false, "a fallback starts off unless it is the feature's own web search")
        #expect(ask.arguments.map(\.name) == ["prompt"])
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func tabAndFallbackHandTheTypedTextOver() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Rayleigh."]))
        #expect(try await ai.harness.pressTab("why is the sky blue") == nil)
        #expect(ai.shownText == "> why is the sky blue\n\nRayleigh.")

        ai.stubAnthropic(AnthropicSSE.answer(["Again."]))
        try await ai.harness.runFallback("ask", text: "typed in root")
        #expect(try ai.sentMessages(1) == [["user", "typed in root"]])
    }

    @Test func theAnswersActions() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        let answer = "Use this:\n\n```swift\nlet a = 1\n```\n\nOr this:\n\n~~~\nlet b = 2\n~~~\n"
        ai.stubAnthropic(AnthropicSSE.answer([answer]))
        try await ai.harness.run("ask", arguments: ["prompt": "code please"])
        #expect(
            ai.harness.actions().map(\.title) == [
                "Copy Answer", "Paste Answer", "Copy Last Code Block", "Regenerate", "Continue in Chat",
            ])
        #expect(ai.harness.actions().secondary?.title == "Paste Answer")

        try await ai.harness.performPrimary()
        #expect(ai.fakes.pasteboard.copiedTexts == [answer])
        #expect(ai.harness.huds.last == "Copied Answer")

        try await ai.harness.perform("Copy Last Code Block")
        #expect(ai.fakes.pasteboard.copiedTexts.last == "let b = 2")

        try await ai.harness.perform("Paste Answer")
        #expect(ai.fakes.pasteboard.pastedTexts == [answer])
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func pastingNeedsAccessibilityAndAsksOnlyThroughTheHost() async throws {
        let ai = try await AIHarness(provider: .anthropic, permissions: .notDetermined)
        ai.stubAnthropic(AnthropicSSE.answer(["Answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await ai.harness.perform("Paste Answer")
        }
        #expect(ai.fakes.permissions.requests.isEmpty)
        #expect(ai.fakes.pasteboard.pastedTexts.isEmpty)
    }

    @Test func regenerateAsksAgainAndReplacesTheAnswer() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["First try."]))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        ai.stubAnthropic(AnthropicSSE.answer(["Second try."]))
        try await ai.harness.perform("Regenerate")
        #expect(ai.shownText == "> q\n\nSecond try.")
        #expect(try ai.sentMessages(1) == [["user", "q"]])
        #expect(ai.session?.conversation.messages.count == 2)
    }

    @Test func regenerateAfterAFailureTriesAgain() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.fakes.http.stub(AnthropicProvider.endpoint) { _ in .failure(URLError(.notConnectedToInternet)) }
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.harness.actions().map(\.title) == ["Regenerate", "Continue in Chat"])
        ai.stubAnthropic(AnthropicSSE.answer(["Back online."]))
        try await ai.harness.perform("Regenerate")
        #expect(ai.shownText == "> q\n\nBack online.")
    }

    @Test func continueInChatKeepsTheConversation() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Paris."]))
        try await ai.harness.run("ask", arguments: ["prompt": "capital of France"])
        try await ai.harness.perform("Continue in Chat")

        #expect(ai.harness.pages.count == 1)
        #expect(ai.session?.mode == .chat)
        #expect(ai.session?.pageTitle == "capital of France")
        #expect(ai.shownText == "> capital of France\n\nParis.")
        let stored = try await ai.feature.store.all()
        #expect(stored.map(\.displayTitle) == ["capital of France"])
        #expect(stored.first?.messages.map(\.text) == ["capital of France", "Paris."])

        ai.stubAnthropic(AnthropicSSE.answer(["About two million."]))
        try await ai.harness.followUp("population?")
        #expect(try await ai.feature.store.all().first?.messages.count == 4)
        #expect(ai.harness.actions().map(\.title).last == "New Chat")
    }

    @Test func askAIKeepsNothingByItself() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        try await ai.harness.followUp("more")
        #expect(try await ai.feature.store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ai.feature.store.folder.path))
    }

    @Test func anEmptyFollowUpSendsNothing() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(AnthropicSSE.answer(["Answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        try await ai.harness.followUp("   \n")
        #expect(ai.fakes.http.requests.count == 1)
    }

    @Test func aFollowUpWhileStreamingKeepsThePartialAnswer() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(
            [
                AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0),
                AnthropicSSE.textDelta("Partial", index: 0),
            ],
            keepsOpen: true)
        let session = AIFeature.askSession("first", services: ai.feature.services)
        var detail = Detail()
        var iterator = session.start().makeAsyncIterator()
        while let update = try await iterator.next() {
            detail.apply(update)
            if case .markdown(let text) = detail.body, text.hasSuffix("Partial") { break }
        }
        ai.stubAnthropic(AnthropicSSE.answer(["Second."]))
        for try await update in session.followUp("second") { detail.apply(update) }
        #expect(detail.body == .markdown("> first\n\nPartial\n\n**Stopped**\n\n---\n\n> second\n\nSecond."))
        #expect(try ai.sentMessages(1) == [["user", "first"], ["assistant", "Partial"], ["user", "second"]])
    }

    @Test func anAnswerStoppedBeforeItsFirstWordLeavesValidTurns() {
        let request = ModelRequest(
            system: "",
            turns: [ModelTurn(.user, "one"), ModelTurn(.assistant, ""), ModelTurn(.user, "two")],
            length: .standard)
        #expect(request.normalizedTurns == [ModelTurn(.user, "one\n\ntwo")])
    }

    @Test func aStoppedAnswerStillOffersItsCodeBlock() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.stubAnthropic(
            [
                AnthropicSSE.messageStart(), AnthropicSSE.textStart(index: 0),
                AnthropicSSE.textDelta("Try:\n```\nmake test\n```\nThen", index: 0),
            ],
            keepsOpen: true)
        let session = AIFeature.askSession("how", services: ai.feature.services)
        var detail = Detail()
        var iterator = session.start().makeAsyncIterator()
        while let update = try await iterator.next() {
            detail.apply(update)
            if case .markdown(let text) = detail.body, text.hasSuffix("Then") { break }
        }
        session.interrupt()
        try await eventually { session.lastCodeBlock == "make test" }
        #expect(session.actions(for: detail).map(\.title).contains("Copy Last Code Block"))
    }
}
