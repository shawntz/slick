import Foundation
import FoundationModels
import Kit
import KitTesting
import Testing

@testable import AI

@Suite("On-device model and setup", .timeLimit(.minutes(1)))
@MainActor
struct SetupAndOnDeviceTests {
    @Test func theOnDeviceModelIsTheDefaultAndSendsNothing() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("ask", arguments: ["prompt": "what is glass"])
        #expect(ai.shownText == "> what is glass\n\nOn-device answer.")
        #expect(ai.harness.detail?.metadata.last == .label("Sent To", value: "Nothing leaves this Mac"))
        #expect(ai.fakes.http.requests.isEmpty)
        #expect(
            ai.onDevice.requests == [
                .init(instructions: Prompts.defaultSystem, prompt: "what is glass", maximumTokens: nil)
            ])
        #expect(ai.harness.pages.count == 1)
    }

    @Test func followUpsCarryTheConversationInThePrompt() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("ask", arguments: ["prompt": "first"])
        ai.onDevice.pieces = ["Second answer."]
        try await ai.harness.followUp("second")
        let prompt = try #require(ai.onDevice.requests.last?.prompt)
        #expect(prompt.contains("User: first"))
        #expect(prompt.contains("Assistant: On-device answer."))
        #expect(prompt.hasSuffix("second"))
        #expect(ai.shownText == "> first\n\nOn-device answer.\n\n---\n\n> second\n\nSecond answer.")
    }

    @Test func shortAnswersLimitTheOnDeviceModel() async throws {
        let ai = try await AIHarness()
        ai.settings[AISettings.responseLength] = .short
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.onDevice.requests.last?.maximumTokens == 512)
    }

    @Test func anOnDeviceFailureShowsItsWords() async throws {
        let ai = try await AIHarness()
        ai.onDevice.failure = Strings.Failures.onDeviceTooLong
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        #expect(ai.shownText.contains("**Conversation Too Long**"))
    }

    @Test func withoutAnyProviderASetupFormComesFirstThenTheAnswer() async throws {
        let ai = try await AIHarness(onDeviceStatus: .notEligible)
        try await ai.harness.run("ask", arguments: ["prompt": "what is glass"])
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected the setup form")
            return
        }
        #expect(form.title == "Set Up AI")
        #expect(form.initialValues.text("provider") == ProviderKind.anthropic.rawValue)
        #expect(ai.fakes.http.requests.isEmpty)

        try ai.harness.fill("provider", text: ProviderKind.onDevice.rawValue)
        await #expect(throws: HarnessError.invalidForm(["provider": "This Mac cannot run Apple's on-device model."])) {
            try await ai.harness.submit()
        }
        try ai.harness.fill("provider", text: ProviderKind.anthropic.rawValue)
        await #expect(throws: HarnessError.self) { try await ai.harness.submit() }

        try ai.harness.fill("anthropicKey", text: "  \(AIHarness.anthropicKey)\n")
        try ai.harness.fill("anthropicModel", text: AnthropicModel.sonnet.rawValue)
        ai.stubAnthropic(AnthropicSSE.answer(["Amorphous."]))
        try await ai.harness.submit()

        #expect(ai.harness.pages.count == 1, "the answer replaced the form")
        #expect(ai.shownText == "> what is glass\n\nAmorphous.")
        #expect(ai.fakes.secrets.values["ai.anthropicKey"] == AIHarness.anthropicKey)
        #expect(ai.settings[AISettings.provider] == .anthropic)
        #expect(ai.settings[AISettings.anthropicModel] == .sonnet)
        #expect(try ai.requestBody()["model"] as? String == "claude-sonnet-5-5")
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func setupChecksTheServerFields() async throws {
        let ai = try await AIHarness(onDeviceStatus: .notEnabled)
        try await ai.harness.run("setup")
        try ai.harness.fill("provider", text: ProviderKind.openAICompatible.rawValue)
        try ai.harness.fill("serverAddress", text: "localhost:11434")
        await #expect(
            throws: HarnessError.invalidForm([
                "serverAddress": FieldError(Strings.Setup.serverAddressInvalid),
                "serverModel": FieldError(Strings.Setup.serverModelMissing),
            ])
        ) { try await ai.harness.submit() }
        try ai.harness.fill("serverAddress", text: "http://localhost:11434/v1")
        try ai.harness.fill("serverModel", text: "test-model")
        try await ai.harness.submit()
        #expect(ai.harness.huds == [.success("AI Provider Saved")])
        #expect(ai.settings[AISettings.provider] == .openAICompatible)
        #expect(ai.settings[AISettings.serverAddress] == "http://localhost:11434/v1")
        #expect(ai.fakes.secrets.values["ai.serverKey"] == nil)
    }

    @Test func aChosenProviderWithoutAKeyAsksForIt() async throws {
        let ai = try await AIHarness()
        ai.settings[AISettings.provider] = .anthropic
        try await ai.harness.run("ask", arguments: ["prompt": "q"])
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected the setup form")
            return
        }
        #expect(form.initialValues.text("provider") == ProviderKind.anthropic.rawValue)
        let descriptions = form.fields.compactMap { field -> String? in
            if case .description(let text) = field.kind { return text }
            return nil
        }
        #expect(descriptions.first == Strings.Setup.intro(reason: .missingAnthropicKey))
    }

    @Test func aKeyWithSpacesIsRefused() async throws {
        let errors = await AIFeature.validateSetup(
            FormValues(["provider": .text("anthropic"), "anthropicKey": .text("sk-ant one")]),
            onDevice: FakeOnDeviceModel(), hasAnthropicKey: false)
        #expect(errors["anthropicKey"] == FieldError(Strings.Setup.keyHasSpaces))
    }

    @Test func eachUnavailableReasonHasItsOwnWords() {
        #expect(AppleOnDeviceModel.status(of: .available) == .available)
        #expect(AppleOnDeviceModel.status(of: .unavailable(.deviceNotEligible)) == .notEligible)
        #expect(AppleOnDeviceModel.status(of: .unavailable(.appleIntelligenceNotEnabled)) == .notEnabled)
        #expect(AppleOnDeviceModel.status(of: .unavailable(.modelNotReady)) == .notReady)
        let notes = [OnDeviceStatus.available, .notEligible, .notEnabled, .notReady].map(Strings.Setup.onDeviceNote)
        #expect(Set(notes).count == 4)
    }

    @Test func otherRunsGetTheSimulatedModel() async throws {
        for environment in [RunEnvironment.selftest, .scenario, .bench] {
            let context = FakeServices().context(featureID: "ai", environment: environment)
            #expect(context.service(OnDeviceModelKey.self) is SimulatedOnDeviceModel)
        }
        let harness = FeatureHarness(AIFeature.self)
        try await harness.run("ask", arguments: ["prompt": "q"])
        guard case .markdown(let text) = harness.detail?.body else {
            Issue.record("expected an answer")
            return
        }
        #expect(text == "> q\n\n" + Strings.Simulated.answer)
        #expect(harness.fakes.http.requests.isEmpty)
    }
}

@Suite("Privacy", .timeLimit(.minutes(1)))
@MainActor
struct PrivacyTests {
    @Test func activationReadsAndSendsNothing() async throws {
        let ai = try await AIHarness(provider: .anthropic, permissions: .notDetermined)
        #expect(ai.fakes.http.requests.isEmpty)
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.onDevice.statusReads == 0)
        #expect(ai.fakes.permissions.requests.isEmpty)
        #expect(ai.fakes.permissions.openStreamCount == 0)
        #expect(ai.fakes.pasteboard.copied.isEmpty)
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func turningTheFeatureOffAndOnLeavesOneListener() async throws {
        let ai = try await AIHarness()
        await ai.harness.activate()
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()
        ai.settings[AISettings.provider] = .anthropic
        try await ai.harness.settle()
        await ai.harness.deactivate()
        ai.settings[AISettings.provider] = .onDevice
        try await ai.harness.settle()
        #expect(ai.fakes.http.requests.isEmpty)
    }

    @Test func aDeepLinkAskShowsAFormAndSendsNothingUntilSubmitted() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        try await ai.harness.run("ask", arguments: ["prompt": "from a web page"], launch: .deeplink)
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.initialValues.text("text") == "from a web page")
        #expect(ai.fakes.http.requests.isEmpty)
        ai.stubAnthropic(AnthropicSSE.answer(["Fine."]))
        try ai.harness.fill("text", text: "edited question")
        try await ai.harness.submit()
        #expect(try ai.sentMessages() == [["user", "edited question"]])
        #expect(ai.harness.pages.count == 1)
    }

    @Test func aDeepLinkTextCommandNeverReadsTheSelection() async throws {
        let ai = try await AIHarness(provider: .anthropic)
        ai.fakes.selection.selection = .text("private selected text")
        try await ai.harness.run("improve-writing", launch: .deeplink)
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.fakes.http.requests.isEmpty)
        ai.stubAnthropic(AnthropicSSE.answer(["Better."]))
        try ai.harness.fill("text", text: "typed text")
        try await ai.harness.submit()
        #expect(ai.fakes.selection.reads == 0)
        let sent = try ai.sentMessages().first?.last ?? ""
        #expect(sent.contains("typed text"))
        #expect(!sent.contains("private selected text"))
        #expect(ai.harness.actions().first?.title == "Copy Result", "nothing was selected, so copying comes first")
    }

    @Test func keysAndAnswersNeverReachTheLog() throws {
        let sources = try FileManager.default.subpathsOfDirectory(atPath: Self.sourceFolder.path)
        for path in sources where path.hasSuffix(".swift") {
            let text = try String(contentsOf: Self.sourceFolder.appending(path: path), encoding: .utf8)
            #expect(!text.contains("context.log") && !text.contains("import os"), "\(path) logs")
            #expect(!text.contains("print(") && !text.contains("NSLog"), "\(path) prints")
        }
    }

    private static var sourceFolder: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/AI")
    }
}
