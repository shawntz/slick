import Foundation
import Kit
import KitTesting
import Testing

@testable import Define

@Suite("Declarations", .timeLimit(.minutes(1)))
struct DeclarationTests {
    @Test func theManifestDeclaresPasteForAccessibility() {
        let manifest = DictionaryFeature.manifest
        #expect(manifest.id == "dictionary")
        #expect(manifest.isEnabledByDefault)
        #expect(manifest.permissions.map(\.permission) == [.accessibility])
        #expect(manifest.permissions.allSatisfy { $0.reason.first?.isUppercase == true && $0.reason.hasSuffix(".") })
    }

    @Test func commandsAndTheirArguments() throws {
        let harness = makeHarness()
        #expect(harness.issues.isEmpty)
        let define = try harness.command("define")
        #expect(define.title == "Define Word")
        #expect(define.keywords.contains("define"))
        #expect(define.arguments.map(\.name) == ["word"])
        #expect(define.requires.isEmpty)
        #expect(define.fallback?.title("lantern") == "Define \"lantern\"")
        let pasted = String(repeating: "word ", count: 200_000)
        let clock = ContinuousClock()
        var title: String?
        let elapsed = clock.measure { title = define.fallback?.title(pasted) }
        #expect(title == "Define \"" + String(pasted.prefix(60)) + "…\"")
        #expect(elapsed < .milliseconds(5), "\(elapsed)")
        let spell = try harness.command("spell")
        #expect(spell.title == "Check Spelling")
        #expect(spell.keywords.contains("spell"))
        #expect(spell.arguments.map(\.name) == ["word"])
    }

    @Test func everyRunOutsideTheAppGetsFixturesNotTheSystem() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let harness = FeatureHarness(DictionaryFeature.self, environment: environment)
            #expect(harness.feature.pages.lookup.service is FixtureLookup, "\(environment)")
        }
        let context = FakeServices().context(featureID: "dictionary", environment: .live)
        #expect(LookupServiceKey.live(context) is SystemLookup)
    }

    /// Nothing is looked up, asked for or opened when the feature turns on or off.
    @Test func activatingDoesNothing() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        await harness.activate()
        await harness.deactivate()
        await harness.activate()
        try await harness.settle()
        #expect(lookup.recorded.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
    }

    @Test func theSettingsHaveSafeDefaultsAndSayWhatIsStoredAndSent() async throws {
        let harness = makeHarness()
        let settings = harness.context.settings
        #expect(settings[DefineSettings.keywords])
        #expect(!settings[DefineSettings.singleWords])
        #expect(settings[DefineSettings.spellingReturn] == .copy)
        let pane = try #require(harness.feature.settingsPane)
        let items = pane.sections.flatMap(\.items)
        let keys = items.compactMap(\.control.key?.name)
        #expect(keys == ["keywords", "singleWords", "spellingReturn"])
        #expect(items.contains { $0.title == DefineStrings.privacyNote })
        #expect(DefineStrings.privacyNote.contains("stores nothing"))
        #expect(DefineStrings.privacyNote.contains("sends nothing over the network itself"))
        #expect(DefineStrings.privacyNote.contains("wikipedia.org"), "the one host macOS may reach is named")
        try await harness.pressSettingsButton(DefineStrings.openDictionary)
        #expect(harness.fakes.workspace.launched == ["com.apple.Dictionary"])
    }

    /// Titles a person reads use title case and no full stop. Messages are sentences.
    @Test func titlesUseTitleCaseAndMessagesAreSentences() {
        let small: Set<String> = ["a", "an", "and", "in", "of", "to", "the", "for", "on", "or"]
        let titles = [
            DefineStrings.defineCommand, DefineStrings.spellCommand, DefineStrings.definitionSection,
            DefineStrings.didYouMeanSection, DefineStrings.suggestionsSection, DefineStrings.typeAWordTitle,
            DefineStrings.tooLongTitle, DefineStrings.noDefinitionTitle, DefineStrings.oneWordTitle,
            DefineStrings.showDefinition, DefineStrings.copyDefinition, DefineStrings.copiedDefinition,
            DefineStrings.pasteDefinition, DefineStrings.openInDictionary, DefineStrings.copyWord,
            DefineStrings.copiedWord, DefineStrings.pasteWord, DefineStrings.defineAction, DefineStrings.spellAction,
            DefineStrings.rootDefinitionSection, DefineStrings.rootSpellingSection,
            DefineStrings.rootDictionarySection, DefineStrings.mainSearchSection, DefineStrings.spellingSection,
            DefineStrings.dictionariesSection, DefineStrings.privacySection, DefineStrings.openDictionary,
        ]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            let words = title.split(separator: " ")
            for (index, word) in words.enumerated() where index == 0 || !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true, "\(title)")
            }
        }
        let sentences = [
            DefineStrings.summary, DefineStrings.accessibilityReason, DefineStrings.defineHint,
            DefineStrings.spellHint, DefineStrings.tooLongMessage, DefineStrings.noDefinitionMessage("x"),
            DefineStrings.oneWordMessage, DefineStrings.keywordsInfo, DefineStrings.singleWordsInfo,
            DefineStrings.spellingReturnInfo, DefineStrings.accessibilityInfo, DefineStrings.sourcesNote,
            DefineStrings.openDictionaryInfo, DefineStrings.privacyNote,
        ]
        for sentence in sentences {
            #expect(sentence.first?.isUppercase == true && sentence.hasSuffix("."), "\(sentence)")
        }
    }
}

@Suite("Define Word", .timeLimit(.minutes(1)))
struct DefineWordTests {
    @Test func aFoundWordOpensAReadablePage() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "lantern"])
        #expect(harness.pageTitle == "lantern")
        let markdown = try #require(harness.shownMarkdown)
        #expect(markdown.hasPrefix("# lantern\n\nlan·tern  \\| ˈlantərn \\|"))
        #expect(markdown.contains("### noun"))
        #expect(markdown.contains("1. a lamp in a case"))
        #expect(markdown.contains("  - the glazed room"))
        #expect(markdown.contains("### Origin"))
        #expect(harness.actionIDs == ["copy-definition", "paste-definition", "open-in-dictionary", "copy-word"])
        #expect(harness.issues.isEmpty)
    }

    @Test func returnCopiesTheDefinition() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "lantern"])
        try await harness.performPrimary()
        let copied = try #require(harness.fakes.pasteboard.copiedTexts.first)
        #expect(copied.hasPrefix("lantern\nlan·tern  | ˈlantərn |\n\nnoun\n1. a lamp in a case"))
        #expect(harness.huds == ["Copied Definition"])
        #expect(harness.isClosed)
    }

    @Test func pasteAsksForAccessibilityFirst() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let harness = makeHarness(fakes: fakes)
        try await harness.run("define", arguments: ["word": "lantern"])
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await harness.performSecondary()
        }
        #expect(harness.fakes.pasteboard.pastes.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
        harness.grantsMissingPermissions = true
        try await harness.perform("paste-definition")
        #expect(harness.fakes.permissions.requests == [.accessibility])
        #expect(harness.fakes.pasteboard.pastedTexts.first?.hasPrefix("lantern\n") == true)
    }

    @Test func openInDictionaryUsesTheWorkspaceWithADictLink() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "ice cream"])
        try await harness.perform("open-in-dictionary")
        #expect(harness.fakes.workspace.opened == [URL(string: "dict://ice%20cream")!])
        #expect(harness.isClosed)
    }

    @Test func copyWordCopiesTheHeadword() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "lanterns"])
        #expect(harness.pageTitle == "lantern")
        try await harness.perform("copy-word")
        #expect(harness.fakes.pasteboard.copiedTexts == ["lantern"])
        #expect(harness.huds == ["Copied Word"])
    }

    @Test func aWordInAnotherScriptShowsItsEntryWhole() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "猫"])
        #expect(harness.pageTitle == "猫")
        #expect(harness.shownMarkdown == "# 猫\n\n" + FixtureLookup.cat)
    }

    @Test func aMisspelledWordListsSuggestionsThatOpenTheirDefinition() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "lantren"])
        #expect(harness.page?.query == "lantren")
        #expect(harness.sections.map(\.title) == ["Did You Mean"])
        #expect(harness.titles == ["lantern", "lanterns"])
        #expect(harness.actionIDs == ["show-definition", "copy-word", "paste-word", "open-in-dictionary"])
        let detail = try await harness.loadDetail()
        guard case .markdown(let markdown) = detail?.body else {
            Issue.record("no detail beside the suggestion")
            return
        }
        #expect(markdown.hasPrefix("# lantern"))
        try await harness.performPrimary()
        #expect(harness.pageTitle == "lantern")
        #expect(harness.issues.isEmpty)
    }

    @Test func anUnknownWordSaysSo() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "xqzzv"])
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "No Definition Found")
        #expect(harness.page?.emptyState?.message == DefineStrings.noDefinitionMessage("xqzzv"))
    }

    @Test func anUnknownPhraseGetsNoSpellingGuesses() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        try await harness.run("define", arguments: ["word": "blue lantren"])
        #expect(harness.rows.isEmpty)
        #expect(!lookup.recorded.contains { $0.hasPrefix("spelling:") })
    }

    @Test func withoutAWordItOpensAPageToTypeInto() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        try await harness.run("define")
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Type a Word")
        #expect(lookup.recorded.isEmpty)
        try await harness.setQuery("harbor")
        #expect(harness.sections.map(\.title) == ["Definition"])
        #expect(harness.titles == ["harbor"])
        #expect(harness.rows.first?.subtitle == "a sheltered stretch of water where ships can stay safely")
        let detail = try await harness.loadDetail()
        guard case .markdown(let markdown) = detail?.body else {
            Issue.record("no detail beside the entry")
            return
        }
        #expect(markdown.hasPrefix("# harbor"))
        // The detail reuses the entry the list found.
        #expect(lookup.recorded == ["definition:harbor"])
        #expect(
            harness.actionIDs == [
                "show-definition", "copy-definition", "paste-definition", "open-in-dictionary", "copy-word",
            ])
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.copiedTexts.first?.hasPrefix("harbor\n") == true)
    }

    @Test func emptyAndWhitespaceWordsOpenTheTypingPage() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "  \n "])
        #expect(harness.page?.emptyState?.title == "Type a Word")
    }

    @Test func veryLongInputNeverReachesTheSystem() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        harness.throwsActionErrors = false
        try await harness.run("define", arguments: ["word": String(repeating: "word ", count: 100_000)])
        #expect(harness.toasts.map(\.title) == ["Too Long to Look Up"])
        #expect(lookup.recorded.isEmpty)
        try await harness.run("define")
        try await harness.setQuery(String(repeating: "a", count: 81))
        #expect(harness.page?.emptyState?.title == "Too Long to Look Up")
        #expect(lookup.recorded.isEmpty)
    }

    @Test func theFallbackDefinesTheTypedText() async throws {
        let harness = makeHarness()
        try await harness.runFallback("define", text: "harbour")
        #expect(harness.pageTitle == "harbor")
    }

    @Test func aDeepLinkOnlyShowsAPage() async throws {
        let harness = makeHarness()
        try await harness.run("define", arguments: ["word": "lantern"], launch: .deeplink)
        #expect(harness.pageTitle == "lantern")
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
    }

    @Test func showDefinitionForAWordWithNoEntryShowsAFailure() async throws {
        let harness = makeHarness()
        harness.throwsActionErrors = false
        try await harness.run("spell", arguments: ["word": "recieve"])
        try harness.select(title: "relieve")
        try await harness.perform("show-definition")
        #expect(harness.visibleToast?.title == "No Definition Found")
        #expect(harness.pages.count == 1)
    }
}

@Suite("Check Spelling", .timeLimit(.minutes(1)))
struct CheckSpellingTests {
    @Test func theTypedWordComesFirstThenSuggestions() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "recieve"])
        #expect(harness.titles == ["recieve", "receive", "relieve"])
        #expect(harness.sections.map(\.title) == [nil, "Suggestions"])
        #expect(harness.rows.first?.subtitle == "Not in the spell checker's dictionary")
        #expect(harness.rows.first?.titleHighlights == [0..<7])
        #expect(harness.issues.isEmpty)
    }

    @Test func returnCopiesTheChosenSpelling() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "recieve"])
        try harness.select(title: "receive")
        #expect(harness.actionIDs == ["copy-word", "paste-word", "show-definition", "open-in-dictionary"])
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.copiedTexts == ["receive"])
        #expect(harness.huds == ["Copied Word"])
    }

    @Test func commandReturnPastesTheChosenSpelling() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "recieve"])
        try harness.select(title: "receive")
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["receive"])
    }

    @Test func theSettingCanMakeReturnPaste() async throws {
        let harness = makeHarness()
        harness.context.settings[DefineSettings.spellingReturn] = .paste
        try await harness.run("spell", arguments: ["word": "recieve"])
        try harness.select(title: "receive")
        #expect(harness.actionIDs == ["paste-word", "copy-word", "show-definition", "open-in-dictionary"])
        try await harness.performPrimary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["receive"])
        try await harness.run("spell", arguments: ["word": "recieve"])
        try harness.select(title: "receive")
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.copiedTexts.last == "receive")
    }

    @Test func showDefinitionAndOpenInDictionaryFromASpelling() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "lantren"])
        try harness.select(title: "lantern")
        try await harness.perform("open-in-dictionary")
        #expect(harness.fakes.workspace.opened == [URL(string: "dict://lantern")!])
        try await harness.run("spell", arguments: ["word": "lantren"])
        try harness.select(title: "lantern")
        try await harness.perform("show-definition")
        #expect(harness.pageTitle == "lantern")
    }

    @Test func verdictsForCorrectUnknownAndUncheckedWords() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "harbour"])
        #expect(harness.rows.first?.subtitle == "Spelled correctly")
        #expect(harness.titles == ["harbour", "harbor", "harbours"])
        try await harness.setQuery("xqzzv")
        #expect(harness.titles == ["xqzzv"])
        #expect(harness.sections.count == 1)
        try await harness.setQuery("日本語")
        #expect(harness.rows.first?.subtitle == "No spelling language on this Mac covers this word")
        try await harness.setQuery("приветт")
        #expect(harness.titles == ["приветт", "привет", "привета"])
    }

    @Test func moreThanOneWordAsksForOne() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        try await harness.run("spell", arguments: ["word": "ice cream"])
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Type One Word")
        #expect(lookup.recorded.isEmpty)
    }

    @Test func withoutAWordItWaitsForTyping() async throws {
        let lookup = RecordingLookup()
        let harness = makeHarness(lookup)
        try await harness.run("spell")
        #expect(harness.page?.emptyState?.title == "Type a Word")
        #expect(lookup.recorded.isEmpty)
    }

    /// Rows are rebuilt from their payload alone, as after root search keeps a snapshot.
    @Test func actionsWorkFromARowRebuiltFromItsSnapshot() async throws {
        let harness = makeHarness()
        try await harness.run("spell", arguments: ["word": "recieve"])
        let row = try #require(harness.rows.last)
        let snapshot = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(row))
        #expect(
            harness.feature.pages.actions(for: snapshot).map(\.id) == harness.feature.pages.actions(for: row).map(\.id))
        #expect(row.memory == .never)
        #expect(row.represents == .text("relieve"))
    }
}

@Suite("Universal actions", .timeLimit(.minutes(1)))
struct UniversalActionTests {
    @Test func aSelectedWordCanBeDefinedOrChecked() async throws {
        let harness = makeHarness()
        #expect(harness.universalActions(for: .text("lantern")).map(\.title) == ["Define Word", "Check Spelling"])
        try await harness.performUniversal("define", on: .text("  lantern\n"))
        #expect(harness.pageTitle == "lantern")
        try await harness.performUniversal("spell", on: .text("recieve"))
        #expect(harness.titles == ["recieve", "receive", "relieve"])
        #expect(harness.issues.isEmpty)
    }

    @Test func aSelectedPhraseCanOnlyBeDefined() {
        let harness = makeHarness()
        #expect(harness.universalActions(for: .text("ice cream")).map(\.title) == ["Define Word"])
    }

    @Test func longSelectionsURLsAndFilesGetNothing() {
        let harness = makeHarness()
        let huge = Selection.text(String(repeating: "text ", count: 2_000_000))
        let clock = ContinuousClock()
        var actions: [Action] = []
        let elapsed = clock.measure { actions = harness.universalActions(for: huge) }
        #expect(actions.isEmpty)
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
        #expect(harness.universalActions(for: .text("   ")).isEmpty)
        #expect(harness.universalActions(for: .url(URL(string: "https://example.com")!)).isEmpty)
        #expect(harness.universalActions(for: .files([URL(filePath: "/tmp/example.txt")])).isEmpty)
    }
}
