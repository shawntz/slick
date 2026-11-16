import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

@Suite("Translate page", .timeLimit(.minutes(1)))
struct PageTests {
    @Test func thePageTranslatesTheSearchFieldIntoTheMenusLanguage() async throws {
        let harness = await readyHarness()
        try await harness.run("translate")
        let page = try #require(harness.page)
        guard case .list(let list) = page.page else {
            Issue.record("not a list")
            return
        }
        #expect(list.showsDetail)
        #expect(list.searchPlaceholder == "Type text to translate")
        #expect(list.filter?.title == "Translate Into")
        #expect(list.filter?.remembersSelection == false, "the feature remembers the language itself")
        #expect(list.filter?.options.map(\.title).contains("French") == true)
        #expect(page.filter == LanguageTag("en-US").identifier, "Automatic is the user's language")
        #expect(harness.rows.isEmpty)
        #expect(page.emptyState?.title == "Type Text to Translate")

        try await harness.setQuery("La bouilloire bleue chante")
        #expect(harness.titles == ["The blue kettle sings"])
        let row = try #require(harness.selectedRow)
        #expect(row.subtitle == "French \u{2192} English (United States)")
        #expect(row.memory == .never)
        #expect(row.represents == .text("The blue kettle sings"))
        let detail = try #require(try await harness.loadDetail())
        #expect(
            detail
                == .markdown("Detected French, translated into English (United States).\n\n# The blue kettle sings"))
        #expect(harness.issues.isEmpty)
    }

    @Test func pickingALanguageTranslatesAgainAndIsRemembered() async throws {
        let harness = await readyHarness()
        try await harness.openPage(typing: "The blue kettle sings")
        #expect(harness.titles == ["Already in English (United States)"])
        try await harness.setFilter(LanguageTag("es").identifier)
        #expect(harness.titles == ["La tetera azul canta"])
        #expect(harness.context.settings[TranslateSettings.lastTarget] == LanguageTag("es").identifier)
        harness.pop()
        try await harness.run("translate")
        #expect(harness.page?.filter == LanguageTag("es").identifier, "the menu opens on the last language")
    }

    @Test func typingLoadsOnlyForTheQueryAndTheEngineNeverRunsOnAnEmptyField() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        try await harness.run("translate")
        try await harness.setQuery("   ")
        try await harness.setQuery("\u{200B}")
        #expect(engine.recorded == ["languages"])
        try await harness.setQuery("  Bonjour \n")
        #expect(engine.translations == ["translate:Bonjour:fr>en"])
    }

    @Test func textOverTheLimitIsRefusedBeforeAnythingReadsIt() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        try await harness.openPage(typing: String(repeating: "a", count: TranslationText.maximumBytes + 1))
        #expect(harness.rows.isEmpty)
        #expect(harness.page?.emptyState?.title == "Text Too Long")
        #expect(engine.recorded == ["languages"])
    }

    @Test func returnCopiesTheTranslationAndTheOtherActionsWork() async throws {
        let harness = await readyHarness()
        try await harness.openPage(typing: "Bonjour")
        let actions = harness.actions()
        #expect(actions.map(\.title) == ["Copy Translation", "Paste Translation", "Swap Languages", "Copy Original"])
        #expect(actions.map(\.shortcut) == [nil, .secondaryAction, TranslatePages.swapShortcut, .copy])
        #expect(actions[1].requires == [.accessibility])
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .close(hud: HUD("Copied Translation")))
        #expect(harness.fakes.pasteboard.copiedTexts == ["Good morning"])

        try await harness.openPage(typing: "Bonjour")
        try await harness.performSecondary()
        #expect(harness.fakes.pasteboard.pastedTexts == ["Good morning"])

        try await harness.openPage(typing: "Bonjour")
        try await harness.perform("copy-original")
        #expect(harness.fakes.pasteboard.copiedTexts.last == "Bonjour")
        #expect(harness.huds.last == "Copied Original")
        #expect(harness.issues.isEmpty)
    }

    @Test func swapLanguagesTranslatesTheTranslationBack() async throws {
        let harness = await readyHarness()
        try await harness.run("translate")
        try await harness.setFilter(LanguageTag("es").identifier)
        try await harness.setQuery("Seven paper boats")
        #expect(harness.titles == ["Siete barcos de papel"])
        let depth = harness.pages.count
        let outcome = try await harness.perform("swap-languages")
        #expect(outcome.kind == .replace)
        #expect(harness.pages.count == depth, "the swapped page replaces the page")
        #expect(harness.page?.query == "Siete barcos de papel")
        #expect(harness.page?.filter == LanguageTag("en-US").identifier)
        #expect(harness.titles == ["Seven paper boats"])
        #expect(harness.selectedRow?.subtitle == "Spanish \u{2192} English (United States)")
        #expect(harness.context.settings[TranslateSettings.lastTarget] == LanguageTag("en-US").identifier)
    }

    @Test func aPairThatIsNotInstalledNamesTheLanguageAndOpensSystemSettings() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        try await harness.run("translate")
        try await harness.setFilter(LanguageTag("de").identifier)
        try await harness.setQuery("Bonjour")
        #expect(harness.titles == ["Download German to Translate"])
        #expect(harness.selectedRow?.subtitle == "German is not installed on this Mac. Download it in System Settings.")
        #expect(engine.translations.isEmpty, "nothing is translated and nothing downloads")
        let detail = try #require(try await harness.loadDetail())
        guard case .markdown(let text) = detail.body else {
            Issue.record("not Markdown")
            return
        }
        #expect(text.contains("Translate never downloads a language by itself."))
        #expect(harness.actions().map(\.title) == ["Open Translation Languages", "Copy Original"])
        let outcome = try await harness.performPrimary()
        #expect(outcome.kind == .close(hud: nil))
        #expect(
            harness.fakes.workspace.opened.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"
            ])
        #expect(harness.issues.isEmpty)
    }

    /// After a download in System Settings the user comes back to the page, which asks again.
    @Test func thePageTranslatesAgainWhenItShowsAfterAskingForADownload() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        try await harness.run("translate")
        try await harness.setFilter(LanguageTag("de").identifier)
        try await harness.setQuery("Bonjour")
        let asked = engine.recorded.count
        harness.closePanel()
        try await harness.openPanel()
        #expect(engine.recorded.count > asked, "the page loaded again")
        #expect(harness.titles == ["Download German to Translate"])

        // A translated page does not translate again on every summon.
        try await harness.setFilter(LanguageTag("es").identifier)
        let translated = engine.recorded.count
        harness.closePanel()
        try await harness.openPanel()
        #expect(engine.recorded.count == translated)
    }

    @Test func aSecondLanguageInSettingsReloadsAnOpenPage() async throws {
        let harness = await readyHarness()
        try await harness.openPage(typing: "Good morning")
        #expect(harness.titles == ["Already in English (United States)"])
        harness.context.settings[TranslateSettings.secondTarget] = LanguageTag("ja").identifier
        try await harness.waitForChange()
        #expect(harness.titles == ["おはようございます"])
    }

    @Test func otherOutcomesShowWhatWentWrongAndOfferTheOriginal() async throws {
        let harness = await readyHarness()
        try await harness.openPage(typing: "Bláa ketillinn syngur")
        #expect(harness.titles == ["Can\u{2019}t Translate Icelandic"])
        #expect(harness.actions().map(\.title) == ["Copy Original"])
        try await harness.setQuery("qzx vbnm")
        #expect(harness.titles == ["Language Not Recognized"])
        let detail = try #require(try await harness.loadDetail())
        #expect(
            detail
                == .markdown("## Language Not Recognized\n\nType a little more text so its language can be recognized.")
        )
    }

    @Test func fallbackAndTabOpenThePageWithTheTypedText() async throws {
        let harness = await readyHarness()
        try await harness.runFallback("translate", text: "Bonjour")
        #expect(harness.page?.query == "Bonjour")
        #expect(harness.titles == ["Good morning"])
        harness.pop()
        try await harness.pressTab("Buenos días")
        #expect(harness.titles == ["Good morning"])
        harness.pop()
        // From root search the command opens an empty page, whatever was typed.
        try await harness.run("translate", query: "trans", launch: .root)
        #expect(harness.page?.query == "")
    }

    @Test func aDeepLinkOpensAnEmptyPageAndTranslatesNothing() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        try await harness.run("translate", query: "Bonjour", launch: .deeplink)
        #expect(harness.page?.query == "")
        #expect(engine.recorded == ["languages"])
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        #expect(harness.fakes.workspace.opened.isEmpty)
    }

    @Test func theCommandWaitsForTheLanguageListWhenItIsNotLoadedYet() async throws {
        let harness = makeHarness()
        try await harness.run("translate")
        #expect(harness.page?.filter == LanguageTag("en-US").identifier)
        try await harness.setQuery("Bonjour")
        #expect(harness.titles == ["Good morning"])
    }

    @Test func aLongTranslationShowsAsParagraphsAndShortOnesLarge() {
        #expect(TranslationText.markdown("Hello") == "# Hello")
        let medium = String(repeating: "word ", count: 30)
        #expect(TranslationText.markdown(medium).hasPrefix("## word"))
        let long = String(repeating: "word ", count: 100) + "\n\n" + "1. done"
        let markdown = TranslationText.markdown(long)
        #expect(!markdown.hasPrefix("#"))
        #expect(markdown.hasSuffix("\n\n1\\. done"))
        #expect(TranslationText.markdown("a *b* [c]\n# d") == "# a \\*b\\* \\[c\\]\n\n# \\# d")
    }
}
