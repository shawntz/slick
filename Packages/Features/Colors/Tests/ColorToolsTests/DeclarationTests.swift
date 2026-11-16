import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// What the feature declares, what activation does, and its settings.
@Suite("Declarations", .timeLimit(.minutes(1)))
struct DeclarationTests {
    @Test func theManifestCommandsAndProviderAreValid() async throws {
        let harness = await readyHarness()
        let manifest = ColorsFeature.manifest
        #expect(manifest.id == "colors" && manifest.name == "Colors")
        #expect(manifest.isEnabledByDefault)
        #expect(manifest.permissions.map(\.permission) == [.accessibility])
        #expect(harness.feature.commands.map(\.id) == ["pick", "history"])
        #expect(harness.feature.commands.map(\.title) == ["Pick Color", "Color History"])
        #expect(harness.feature.liveProviders.map(\.namespace) == ["colors"])
        #expect(harness.issues.isEmpty)
        #expect(harness.pendingIssues.isEmpty)
    }

    @Test func activationReadsOnlyTheFeaturesOwnFileAndAsksNothing() async throws {
        let sampler = SimulatedColorSampler()
        let fakes = FakeServices(permissions: .denied)
        let harness = await readyHarness(fakes: fakes, sampler: sampler)
        #expect(sampler.count == 0, "nothing shows at activation")
        #expect(fakes.permissions.requests.isEmpty)
        #expect(fakes.permissions.openStreamCount == 0)
        #expect(fakes.pasteboard.copied.isEmpty)
        #expect(fakes.http.requests.isEmpty)
        #expect(fakes.workspace.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.historyFile.path), "activation writes nothing")
    }

    @Test func switchingOffAndOnReadsTheFileAgain() async throws {
        let fakes = FakeServices()
        let harness = await readyHarness(fakes: fakes)
        await harness.deactivate()
        try writeHistory(
            """
            { "version" : 1, "entries" : [ { "id" : "00000000-0000-0000-0000-000000000009",
              "color" : { "red" : 0, "green" : 0, "blue" : 1, "alpha" : 1 }, "date" : "2026-11-14T09:00:00Z" } ] }
            """, in: fakes)
        for _ in 0..<3 {
            await harness.activate()
            await harness.feature.waitUntilReady()
            await harness.deactivate()
        }
        await harness.activate()
        await harness.feature.waitUntilReady()
        #expect(harness.historyHexes == ["#0000FF"])
        // One listener follows the limit, not four.
        harness.context.settings[ColorSettings.historyLimit] = 25
        try await harness.settle()
        #expect(harness.historyHexes == ["#0000FF"])
    }

    @Test func pasteNeedsAccessibilityAndAsksOnlyThroughTheHost() async throws {
        let fakes = FakeServices(permissions: .denied)
        let harness = await readyHarness(fakes: fakes)
        let row = try #require(harness.answerRow("#663399"))
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await harness.performRoot("paste", on: row)
        }
        #expect(fakes.pasteboard.pastedTexts.isEmpty)
        #expect(fakes.permissions.requests.isEmpty, "only the card's Grant button asks")
        try await harness.performRoot("copy-hex", on: row)
        #expect(fakes.pasteboard.copiedTexts == ["#663399"], "copying needs no permission")
    }

    @Test func theSettingsPaneOffersTheThreeSettingsTheBriefAsksFor() async throws {
        let harness = await readyHarness()
        let pane = try #require(harness.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Formats", "Root Search", "History"])
        let items = pane.sections.flatMap(\.items).map(\.title)
        #expect(items == ["Default format", "Hex digits", "Convert colors you type", "Keep at most", "Clear History"])
        #expect(try harness.chooseSetting("Default format", option: "OKLCH, oklch(44.03% 0.1603 303.37)"))
        #expect(harness.context.settings[ColorSettings.defaultFormat] == .oklch)
        #expect(try harness.chooseSetting("Hex digits", option: "Lowercase, #66cc99"))
        #expect(harness.context.settings[ColorSettings.hexCase] == .lowercase)
        #expect(harness.confirmations.isEmpty, "formats lose nothing and ask nothing")
        let footer = try #require(pane.sections.last?.footer)
        #expect(footer.contains(Brand.name))
    }

    @Test func aStoredSettingOfTheWrongTypeReadsAsItsDefault() async throws {
        let harness = await readyHarness()
        let settings = harness.fakes.settings
        settings.set(.string("rainbow"), for: harness.context.settings.storageName(for: "defaultFormat"))
        settings.set(.string("mixed"), for: harness.context.settings.storageName(for: "hexCase"))
        settings.set(.int(-4), for: harness.context.settings.storageName(for: "historyLimit"))
        #expect(harness.answerRow("#66cc99")?.title == "#66CC99")
        #expect(harness.feature.history.limit == 1, "a nonsense size is bounded, never negative")
    }

    @Test func userFacingTitlesUseTitleCaseWithoutAStop() {
        let titles =
            [
                ColorStrings.pickCommand, ColorStrings.historyCommand, ColorStrings.unreadableTitle,
                ColorStrings.emptyTitle,
                ColorStrings.pin, ColorStrings.unpin, ColorStrings.rename, ColorStrings.renameSubmit,
                ColorStrings.delete,
                ColorStrings.deleteConfirm, ColorStrings.clearHistory, ColorStrings.clearQuestion,
                ColorStrings.clearConfirm,
                ColorStrings.clearedToast, ColorStrings.deletedToast, ColorStrings.renamedToast,
                ColorStrings.removedNameToast,
                ColorStrings.readOnlyTitle, ColorStrings.limitConfirm, ColorStrings.limitQuestion(25),
                ColorStrings.openHistory,
                ColorStrings.copyRatio, ColorStrings.copyResult, ColorStrings.copiedResult, ColorStrings.colorNotFound,
                ColorStrings.pinnedSection, ColorStrings.otherFormats,
            ] + ColorFormat.allCases.flatMap { [ColorStrings.copyAs($0), ColorStrings.pasteAs($0)] }
        let small: Set<String> = ["as", "on", "from", "the", "of", "to", "a", "an", "and", "for", "in"]
        for title in titles {
            #expect(!title.hasSuffix("."), "\(title)")
            for (index, word) in title.split(separator: " ").enumerated() where index > 0 {
                let first = word.first.map(String.init) ?? ""
                #expect(first == first.uppercased() || small.contains(String(word)), "\(title): \(word)")
            }
        }
        let sentences = [
            ColorStrings.summary, ColorStrings.unreadableMessage, ColorStrings.emptyMessage, ColorStrings.deleteMessage,
            ColorStrings.clearMessage, ColorStrings.readOnlyMessage, ColorStrings.limitMessage(25),
            ColorStrings.historyLimitInfo, ColorStrings.defaultFormatInfo, ColorStrings.renameInfo,
            ColorStrings.colorNotFoundMessage, ColorStrings.accessibilityReason, ColorStrings.gamutOutside,
        ]
        for sentence in sentences {
            #expect(sentence.hasSuffix("."), "\(sentence)")
        }
    }
}
