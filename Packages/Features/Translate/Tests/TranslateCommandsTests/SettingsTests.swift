import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

@Suite("Settings", .timeLimit(.minutes(1)))
struct SettingsTests {
    func pickerOptions(_ harness: FeatureHarness<TranslateFeature>, _ title: String) -> [String] {
        let items = harness.feature.settingsPane?.sections.flatMap(\.items) ?? []
        guard let item = items.first(where: { $0.title == title }), case .picker(_, let options) = item.control else {
            return []
        }
        return options.map(\.title)
    }

    @Test func theDefaultsChangeNothingUntilTheUserChooses() {
        #expect(TranslateSettings.target.defaultValue == "")
        #expect(TranslateSettings.secondTarget.defaultValue == "")
        #expect(TranslateSettings.keywords.defaultValue)
        #expect(TranslateSettings.lastTarget.defaultValue == "")
    }

    @Test func theLanguageMenusListTheEnginesLanguages() async throws {
        let harness = await readyHarness(RecordingEngine(SimulatedTranslation(preferred: ["fr-FR"])))
        let targets = pickerOptions(harness, "Translate into")
        #expect(targets.first == "Automatic, French")
        #expect(targets.dropFirst().sorted() == harness.feature.translator.catalog?.entries.map(\.title).sorted())
        #expect(targets.count == SimulatedTranslation.standardSupported.count + 1)
        let seconds = pickerOptions(harness, "Second language")
        #expect(seconds.first == "None")
        #expect(seconds.count == targets.count)
    }

    @Test func beforeTheListLoadsTheMenusStillShowWhatIsStored() {
        let harness = makeHarness()
        harness.context.settings[TranslateSettings.target] = LanguageTag("de").identifier
        #expect(pickerOptions(harness, "Translate into") == ["Automatic", "German"])
        #expect(pickerOptions(harness, "Second language") == ["None"])
    }

    @Test func thePaneSaysWhatIsStoredAndOpensSystemSettings() async throws {
        let harness = await readyHarness()
        let pane = try #require(harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Languages", "Root Search", "Downloads", "Permissions", "Privacy"])
        let downloads = try #require(pane.sections.first { $0.title == "Downloads" })
        #expect(!downloads.items.contains { if case .permission = $0.control { true } else { false } })
        let items = pane.sections.flatMap(\.items)
        #expect(items.contains { if case .permission(.accessibility) = $0.control { true } else { false } })
        #expect(items.contains { $0.title.contains("sends nothing over the network") })
        try await harness.pressSettingsButton("Open Translation Languages")
        #expect(
            harness.fakes.workspace.opened.map(\.absoluteString) == [TranslatePages.languageSettingsLink])
    }

    /// The code proves that Translate itself sends nothing and starts no download. Whether the
    /// system's translation service stays on the Mac is not something it can prove, so no text says
    /// that nothing leaves the Mac.
    @Test func theTextClaimsOnlyWhatTheCodeProves() {
        for text in [TranslateStrings.summary, TranslateStrings.privacyNote] {
            #expect(!text.contains("Nothing leaves the Mac"))
            #expect(!text.contains("on the Mac itself"))
            #expect(text.contains("sends nothing over the network itself"))
        }
        #expect(TranslateStrings.privacyNote.contains("starts no download"))
    }

    @Test func choosingALanguageIsUsedAtOnce() async throws {
        let harness = await readyHarness()
        #expect(try harness.chooseSetting("Translate into", option: "Spanish"))
        try await harness.settle()
        #expect(harness.context.settings[TranslateSettings.target] == LanguageTag("es").identifier)
        try await harness.openPage(typing: "Bonjour")
        #expect(harness.page?.filter == LanguageTag("es").identifier)
        #expect(harness.titles == ["Buenos días"])
    }

    @Test func aNewFirstLanguageIsWhatTheMenuOpensOn() async throws {
        let harness = await readyHarness()
        try await harness.run("translate")
        try await harness.setFilter(LanguageTag("ja").identifier)
        #expect(harness.context.settings[TranslateSettings.lastTarget] == LanguageTag("ja").identifier)
        harness.pop()
        #expect(try harness.chooseSetting("Translate into", option: "French"))
        try await harness.settle()
        #expect(harness.context.settings[TranslateSettings.lastTarget] == "")
        try await harness.run("translate")
        #expect(harness.page?.filter == LanguageTag("fr").identifier)
    }

    @Test func theDeclarationsAreReadAgainWhenTheListArrives() async throws {
        let harness = makeHarness()
        let changes = try #require(harness.feature.declarationChanges)
        let before = changes.generation
        await harness.activate()
        await harness.feature.waitUntilReady()
        var stream = changes.stream().makeAsyncIterator()
        if changes.generation == before { _ = await stream.next() }
        #expect(changes.generation > before)
    }
}
