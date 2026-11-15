import Foundation
import Kit
import KitStorage
import KitTesting
import Testing

@testable import AI

@Suite("Custom AI commands", .timeLimit(.minutes(1)))
@MainActor
struct CustomCommandTests {
    private func commandsFile(_ ai: AIHarness) -> JSONFileStore<CustomCommandFile> {
        JSONFileStore(url: ai.harness.context.storage.dataFile(AIFeature.commandsFileName))
    }

    @Test func createdCommandsAreSavedAndRunWithTheirPlaceholders() async throws {
        let ai = try await AIHarness()
        let changes = try #require(ai.feature.declarationChanges)
        let before = changes.generation
        try await ai.harness.run("create-command")
        try ai.harness.fill("title", text: "Rewrite as Haiku")
        try ai.harness.fill(
            "prompt", text: "Rewrite this as a {argument name=\"mood\" default=\"calm\"} haiku: {selection}")
        try await ai.harness.submit()
        #expect(ai.harness.toasts.last?.title == "Saved AI Command")
        #expect(changes.generation > before)

        let saved = try #require(try await commandsFile(ai).load()?.commands.first)
        #expect(saved.title == "Rewrite as Haiku")
        #expect(saved.id.hasPrefix("custom.rewrite-as-haiku-"))
        #expect(saved.replacesSelection)

        let command = try ai.harness.command(saved.id)
        #expect(command.subtitle == "Your AI command")
        #expect(command.arguments.map(\.name) == ["mood"])
        #expect(command.arguments.first?.isOptional == true)

        ai.fakes.selection.selection = .text("the sun sets")
        try await ai.harness.run(saved.id, arguments: ["mood": "joyful"])
        #expect(
            ai.onDevice.requests.last?.prompt == "Rewrite this as a \"\"\"joyful\"\"\" haiku: \"\"\"the sun sets\"\"\"")
        #expect(ai.harness.actions().first?.title == "Replace Selection")
        #expect(ai.shownText == "On-device answer.")
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func aCommandWithoutTheSelectionReadsNothing() async throws {
        let ai = try await AIHarness()
        try await ai.feature.saveCustomCommands([
            CustomCommand(
                id: "custom.joke-0000aaaa", title: "Tell a Joke", prompt: "Tell a joke about {argument name=\"topic\"}",
                replacesSelection: true)
        ])
        try await ai.harness.run("custom.joke-0000aaaa", arguments: ["topic": "cats"])
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.onDevice.requests.last?.prompt == "Tell a joke about \"\"\"cats\"\"\"")
        #expect(ai.harness.actions().map(\.title).prefix(2) == ["Copy Result", "Paste Result"])
        #expect(ai.harness.universalActions(for: .text("x")).map(\.title).contains("Tell a Joke") == false)
    }

    @Test func commandsThatUseTheSelectionAreUniversalActions() async throws {
        let ai = try await AIHarness()
        try await ai.feature.saveCustomCommands([
            CustomCommand(
                id: "custom.bullets-0000bbbb", title: "Make Bullets", prompt: "Bullets: {selection}",
                replacesSelection: false)
        ])
        let actions = ai.harness.universalActions(for: .text("one two"))
        #expect(actions.last?.title == "Make Bullets")
        try await ai.harness.performUniversal("custom.bullets-0000bbbb", on: .text("one two"))
        #expect(ai.onDevice.requests.last?.prompt == "Bullets: \"\"\"one two\"\"\"")
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.harness.actions().first?.title == "Copy Result", "this command does not replace the selection")
    }

    @Test func theFormRefusesMistakes() async throws {
        let ai = try await AIHarness()
        try await ai.harness.run("create-command")
        try ai.harness.fill("title", text: "Improve Writing")
        try ai.harness.fill("prompt", text: "Hi {date offset=\"+1q\"}")
        do {
            try await ai.harness.submit()
            Issue.record("the form should refuse")
        } catch HarnessError.invalidForm(let errors) {
            #expect(errors["title"] == FieldError(Strings.Custom.nameTaken))
            #expect(errors["prompt"]?.range != nil)
        }
        try ai.harness.fill("title", text: "Four")
        try ai.harness.fill(
            "prompt", text: "{argument name=\"a\"} {argument name=\"b\"} {argument name=\"c\"} {argument name=\"d\"}")
        do {
            try await ai.harness.submit()
            Issue.record("the form should refuse four arguments")
        } catch HarnessError.invalidForm(let errors) {
            #expect(errors["prompt"]?.message.hasPrefix("Fix this placeholder: ") == true)
            #expect(errors["prompt"]?.range != nil)
        }
    }

    @Test func editKeepsTheIDAndDeleteAsksFirst() async throws {
        let ai = try await AIHarness()
        let original = CustomCommand(
            id: "custom.shout-0000cccc", title: "Shout", prompt: "Shout {selection}", replacesSelection: true)
        try await ai.feature.saveCustomCommands([original])
        let rowActions = try ai.harness.rowActions(ofCommand: original.id)
        #expect(rowActions.map(\.title) == ["Edit AI Command", "Delete AI Command"])

        try await ai.harness.perform(try #require(rowActions.first), row: nil)
        try ai.harness.fill("title", text: "Shout Loudly")
        try await ai.harness.submit()
        #expect(ai.feature.customCommands.map(\.id) == [original.id])
        #expect(ai.feature.customCommands.first?.title == "Shout Loudly")

        ai.harness.confirmationAnswer = false
        try await ai.harness.perform(try #require(try ai.harness.rowActions(ofCommand: original.id).last), row: nil)
        #expect(ai.feature.customCommands.count == 1)
        ai.harness.confirmationAnswer = true
        try await ai.harness.perform(try #require(try ai.harness.rowActions(ofCommand: original.id).last), row: nil)
        #expect(ai.harness.confirmations.last?.title == "Delete \u{201C}Shout Loudly\u{201D}?")
        #expect(ai.feature.customCommands.isEmpty)
        #expect(try await commandsFile(ai).load()?.commands.isEmpty == true)
        #expect((try? ai.harness.command(original.id)) == nil)
    }

    @Test func aHandEditedFileIsCleanedWhenRead() async throws {
        let ai = try await AIHarness(activate: false)
        let raw = """
            {"commands": [
              {"title": "First\\nLine", "prompt": "One {selection}"},
              {"id": "custom.same", "title": "Two", "prompt": "Two"},
              {"id": "custom.same", "title": "Three", "prompt": "Three"},
              {"id": "bad id!", "title": "Four", "prompt": "Four"},
              {"title": "Empty", "prompt": ""}
            ]}
            """
        let url = ai.harness.context.storage.dataFile(AIFeature.commandsFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: url)
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()

        let commands = ai.feature.customCommands
        #expect(commands.map(\.title) == ["First Line", "Two", "Three", "Four"])
        #expect(Set(commands.map(\.id)).count == 4)
        #expect(commands.allSatisfy { CustomCommandFile.isValidID($0.id) })
        #expect(ai.harness.issues.isEmpty)
    }

    @Test func anUnreadableFileIsNeverOverwritten() async throws {
        let ai = try await AIHarness(activate: false)
        let url = ai.harness.context.storage.dataFile(AIFeature.commandsFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        await ai.harness.activate()
        await ai.feature.waitUntilLoaded()
        try await ai.harness.run("create-command")
        try ai.harness.fill("title", text: "New")
        try ai.harness.fill("prompt", text: "Hello")
        await #expect(throws: Strings.Failures.commandsUnreadable) { try await ai.harness.submit() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test func aDeepLinkShowsThePromptWithoutReadingAnything() async throws {
        let ai = try await AIHarness()
        try await ai.feature.saveCustomCommands([
            CustomCommand(
                id: "custom.mix-0000dddd", title: "Mix",
                prompt: "Use {clipboard} and {selection} about {argument name=\"x\"}", replacesSelection: true)
        ])
        ai.fakes.selection.selection = .text("selected")
        _ = ai.fakes.pasteboard.simulateCopy("copied")
        try await ai.harness.run("custom.mix-0000dddd", arguments: ["x": "linked"], launch: .deeplink)
        guard case .form(let form) = ai.harness.page?.page else {
            Issue.record("expected a form")
            return
        }
        #expect(form.initialValues.text("text") == "Use \"\"\"\"\"\" and \"\"\"\"\"\" about \"\"\"linked\"\"\"")
        #expect(ai.fakes.selection.reads == 0)
        #expect(ai.onDevice.requests.isEmpty)
        try await ai.harness.submit()
        #expect(ai.onDevice.requests.count == 1)
    }
}
