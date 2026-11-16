import Foundation
import Kit
import KitTesting
import Testing

@testable import AI

/// A server that answers with a redirect to another host never receives the key or the prompt
/// there: the request stops at the redirect, and the answer says which hosts were involved.
@Suite("Redirects to another host", .timeLimit(.minutes(1)))
@MainActor
struct RedirectTests {
    private static let elsewhere =
        URL(string: "https://elsewhere.example.test/v1/chat/completions") ?? URL(filePath: "/")

    @Test func aCompatibleServerThatRedirectsElsewhereIsNotFollowed() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        try await ai.fakes.secrets.setSecret("server-test-key", for: "ai." + AISecrets.serverKey)
        ai.fakes.http.stubRedirect(AIHarness.serverURL, to: Self.elsewhere)
        try await ai.harness.run("ask", arguments: ["prompt": "a private question"])
        #expect(
            ai.shownText.contains(
                "**Request Not Forwarded**\n\nlocalhost tried to send the request on to elsewhere.example.test, so "
                    + "it was not sent there. Check the base address in AI settings."))
        #expect(ai.fakes.http.requests.count == 1)
        #expect(ai.fakes.http.requests.allSatisfy { $0.url.host(percentEncoded: false) != "elsewhere.example.test" })
    }

    @Test func anthropicRedirectingElsewhereIsNotFollowed() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.fakes.http.stubRedirect(AnthropicProvider.endpoint, to: Self.elsewhere, status: 308)
        try await ai.harness.run("ask", arguments: ["prompt": "a private question"])
        #expect(ai.shownText.contains("**Request Not Forwarded**"))
        #expect(
            ai.shownText.contains(
                "api.anthropic.com tried to send the request on to elsewhere.example.test, so it was not sent there. "
                    + "Try again in a moment."))
        #expect(ai.fakes.http.requests.allSatisfy { $0.url.host(percentEncoded: false) != "elsewhere.example.test" })
    }

    @Test func aRedirectOnTheSameServerIsFollowed() async throws {
        let ai = try await AIHarness(provider: .openAICompatible)
        let moved = try #require(URL(string: "http://localhost:11434/v2/chat/completions"))
        ai.fakes.http.stubRedirect(AIHarness.serverURL, to: moved)
        ai.fakes.http.stub(moved, chunks: CompletionSSE.answer(["Moved answer."]))
        try await ai.harness.run("ask", arguments: ["prompt": "hello"])
        #expect(ai.shownText.hasSuffix("Moved answer."))
        #expect(ai.fakes.http.requests.map(\.url) == [AIHarness.serverURL, moved])
    }
}
