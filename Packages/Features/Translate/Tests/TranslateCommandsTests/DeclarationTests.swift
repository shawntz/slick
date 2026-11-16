import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

@Suite("Declarations", .timeLimit(.minutes(1)))
struct DeclarationTests {
    @Test func theManifestDeclaresAccessibilityWithAReason() {
        let manifest = TranslateFeature.manifest
        #expect(manifest.id == "translate")
        #expect(manifest.name == "Translate")
        #expect(manifest.isEnabledByDefault)
        #expect(!manifest.isSuggestedInOnboarding)
        #expect(manifest.permissions.map(\.permission) == [.accessibility])
        #expect(manifest.permissions.allSatisfy { $0.reason.first?.isUppercase == true && $0.reason.hasSuffix(".") })
        #expect(manifest.summary.hasSuffix("."))
    }

    @Test func commandsAndWhatTheyDeclare() throws {
        let harness = makeHarness()
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
        let translate = try harness.command("translate")
        #expect(translate.title == "Translate")
        #expect(translate.keywords.contains("tr"))
        #expect(translate.arguments.isEmpty)
        #expect(translate.requires.isEmpty)
        #expect(translate.takesRootQueryOnTab)
        #expect(translate.allowsDeepLinks)
        #expect(translate.fallback?.title("Bonjour") == "Translate \u{201C}Bonjour\u{201D}")
        #expect(
            translate.fallback?.startsOn == false, "a fallback starts off unless it is the feature's own web search")
        let selection = try harness.command("translate-selection")
        #expect(selection.title == "Translate Selection")
        #expect(selection.requires == [.accessibility])
        #expect(selection.allowsDeepLinks == false, "a link may not make the launcher read the selection")
        #expect(selection.showsInRoot)
    }

    @Test func aFallbackTitleReadsOnlyTheStartOfAPaste() throws {
        let harness = makeHarness()
        let pasted = String(repeating: "word ", count: 200_000)
        let clock = ContinuousClock()
        var title: String?
        let elapsed = try clock.measure { title = try harness.command("translate").fallback?.title(pasted) }
        #expect(title == "Translate \u{201C}" + String(pasted.prefix(60)) + "…\u{201D}")
        #expect(elapsed < .milliseconds(250), "\(elapsed)")
    }

    @Test func everyRunOutsideTheAppGetsTheSimulatedEngine() {
        for environment in RunEnvironment.allCases where !environment.touchesRealSystem {
            let harness = FeatureHarness(TranslateFeature.self, environment: environment)
            #expect(harness.feature.translator.engine is SimulatedTranslation, "\(environment)")
        }
        // Making the live engine touches nothing: its calls run only when the feature asks.
        let context = FakeServices().context(featureID: "translate", environment: .live)
        #expect(TranslationEngineKey.live(context) is SystemTranslation)
    }

    @Test func sourcesAndProvidersAreStable() {
        let harness = makeHarness()
        #expect(harness.feature.liveProviders.count == 1)
        #expect(harness.feature.liveProviders.first?.namespace == "translate")
        #expect(harness.feature.catalogSources.isEmpty)
        #expect(harness.feature.universalActions.isEmpty)
    }

    /// Activation lists the languages and does nothing else: no translation, no selection read,
    /// no question, no stream and nothing opened.
    @Test func activationOnlyListsTheLanguages() async throws {
        let engine = RecordingEngine()
        let harness = makeHarness(engine)
        await harness.activate()
        await harness.feature.waitUntilReady()
        try await harness.settle()
        #expect(engine.recorded == ["languages"])
        #expect(harness.fakes.selection.reads == 0)
        #expect(harness.fakes.permissions.requests.isEmpty)
        #expect(harness.fakes.permissions.openStreamCount == 0)
        #expect(harness.fakes.workspace.opened.isEmpty)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        #expect(harness.feature.translator.catalog?.entries.count == SimulatedTranslation.standardSupported.count)
    }

    /// Switching off and on lists the languages again and leaves no listener behind.
    @Test func switchingOffAndOnListsAgainAndKeepsOneSetOfListeners() async throws {
        let engine = RecordingEngine()
        let harness = makeHarness(engine)
        for _ in 0..<3 {
            await harness.activate()
            await harness.feature.waitUntilReady()
            await harness.deactivate()
        }
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(engine.recorded == Array(repeating: "languages", count: 4))
        #expect(engine.translations.isEmpty)
        // One change of a setting is heard once, by the last activation's listener alone.
        let changes = try #require(harness.feature.declarationChanges)
        let before = changes.generation
        harness.context.settings[TranslateSettings.secondTarget] = LanguageTag("fr").identifier
        try await harness.settle()
        #expect(changes.generation == before + 1)
    }

    @Test func withoutLanguagesTheCommandsSaySoAndSettingsShowAStatus() async throws {
        let harness = await readyHarness(ScriptedEngine(languages: []))
        #expect(harness.feature.status?.title == "Translation Is Not Available")
        harness.throwsActionErrors = false
        try await harness.run("translate")
        #expect(harness.pages.isEmpty)
        #expect(harness.toasts.map(\.title) == ["Translation Is Not Available"])
        #expect(harness.instantAnswers(for: "tr Bonjour").first?.rows.first?.title == TranslateStrings.translating)
    }

    @Test func aMacWithLanguagesHasNoStatus() async {
        let harness = await readyHarness()
        #expect(harness.feature.status == nil)
    }
}
