import CoreBridge
import Foundation
import Kit
import KitTesting
import Testing

@testable import Calc

@Suite("Feature, settings and run environments", .timeLimit(.minutes(1)))
struct FeatureTests {
    @Test func declaresOneCommandTheProviderAndAPermissionWithAReason() async throws {
        let harness = await readyHarness()
        #expect(harness.issues.isEmpty)
        #expect(CalculatorFeature.manifest.id == "calculator")
        #expect(CalculatorFeature.manifest.name == "Calculator")
        #expect(CalculatorFeature.manifest.permissions.map(\.permission) == [.accessibility])
        #expect(CalculatorFeature.manifest.permissions.first?.reason.hasPrefix("Paste") == true)
        let command = try harness.command("history")
        #expect(command.title == "Calculator History")
        #expect(command.itemID(feature: "calculator").rawValue == "cmd:calculator.history")
        #expect(command.confirmation == nil && command.requires.isEmpty, "it only opens a page")
        #expect(harness.feature.liveProviders.map(\.namespace) == ["calculator"])
        #expect(harness.feature.status == nil, "the engine loaded")
    }

    @Test func thePaneOffersTheChoicesWithSafeDefaults() async throws {
        let harness = await readyHarness()
        let pane = try #require(harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Answers", "History", "Exchange Rates"])
        let items = pane.sections.flatMap(\.items)
        #expect(
            items.compactMap(\.control.key?.name) == [
                "decimalPlaces", "grouping", "decimalMark", "dateOrder", "clock", "angles", "dollar",
                "keepsHistory", "historyLimit", "downloadsRates",
            ])
        #expect(items.contains { $0.title == "Clear History" })
        let history = try #require(pane.sections[1].footer)
        #expect(history.contains("Features/calculator/history.json") && history.contains(Brand.name))
        let rates = try #require(pane.sections[2].footer)
        #expect(rates.contains("www.ecb.europa.eu") && rates.contains("carries nothing about you"))

        let settings = harness.context.settings
        #expect(settings[CalcSettings.decimalPlaces] == .automatic)
        #expect(settings[CalcSettings.grouping] == .system)
        #expect(settings[CalcSettings.decimalMark] == .system)
        #expect(settings[CalcSettings.angles] == .radians)
        #expect(settings[CalcSettings.dollar] == .automatic)
        #expect(settings[CalcSettings.keepsHistory])
        #expect(settings[CalcSettings.historyLimit] == 100)
        #expect(settings[CalcSettings.downloadsRates])
    }

    @Test func wordingFollowsTheRules() {
        let titles = [
            CalcStrings.copyAnswer, CalcStrings.pasteAnswer, CalcStrings.copyPlainNumber,
            CalcStrings.copyQuestionAndAnswer, CalcStrings.openHistory, CalcStrings.useAgain, CalcStrings.deleteEntry,
            CalcStrings.clearHistory, CalcStrings.historyCommand, CalcStrings.emptyHistoryTitle,
            CalcStrings.historyOffTitle, CalcStrings.ratesLoadingTitle, CalcStrings.ratesUnavailableTitle,
            CalcStrings.ratesOffTitle, CalcStrings.clearedToast, CalcStrings.deletedToast,
            CalcStrings.copiedQuestionAndAnswer, CalcStrings.otherForms,
        ]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            #expect(!title.contains("—"), "\(title)")
        }
        let sentences = [
            CalcStrings.ratesLoadingSubtitle, CalcStrings.ratesUnavailableSubtitle, CalcStrings.ratesOffSubtitle,
            CalcStrings.emptyHistoryMessage, CalcStrings.historyOffMessage, CalcStrings.ratesFooter,
            CalcStrings.decimalPlacesInfo, CalcStrings.accessibilityReason, CalcStrings.summary,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
            #expect(!sentence.contains("—"), "\(sentence)")
        }
        #expect(CalcStrings.copyForm("inverse rate") == "Copy Inverse Rate")
        #expect(CalcStrings.copyForm("ISO 8601") == "Copy ISO 8601")
    }

    @Test func outsideTheLiveAppTheFeatureGetsItsIsolatedServices() async throws {
        for environment in [RunEnvironment.selftest, .scenario, .bench] {
            let context = FakeServices().context(featureID: "calculator", environment: environment)
            #expect(context.service(ExchangeRateServiceKey.self) is SampleRates)
            #expect(context.service(RegionServiceKey.self) is FixedRegion)
        }
        let live = FakeServices().context(featureID: "calculator", environment: .live)
        #expect(live.service(ExchangeRateServiceKey.self) is ReferenceRates)
        #expect(live.service(RegionServiceKey.self) is SystemRegion)
    }

    @Test func aScenarioRunConvertsWithSampleRatesAndNoRequest() async throws {
        let fakes = FakeServices()
        let harness = FeatureHarness(CalculatorFeature.self, environment: .scenario, fakes: fakes)
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(harness.answerRow("2 + 2")?.title == "4")
        _ = harness.answerRow("108 usd in eur")
        await harness.feature.rates.waitForDownload()
        #expect(harness.answerRow("108 usd in eur")?.title == "100 EUR")
        #expect(fakes.http.requests.isEmpty)
    }

    @Test func activationAsksForNothingAndWritesNothing() async throws {
        let fakes = FakeServices(permissions: .denied)
        let rates = ScriptedRates()
        let harness = await readyHarness(fakes: fakes, rates: rates)
        await harness.deactivate()
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(fakes.permissions.requests.isEmpty)
        #expect(fakes.http.requests.isEmpty && rates.downloads.isEmpty)
        #expect(fakes.pasteboard.copied.isEmpty)
        let folder = fakes.storage.dataDirectory(for: "calculator")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing is written until an answer is kept")
    }
}
