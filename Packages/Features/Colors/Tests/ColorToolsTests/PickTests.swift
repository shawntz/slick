import Foundation
import Kit
import KitTesting
import Testing

@testable import ColorTools

/// Pick Color through the simulated sampler, which returns the color the test chose.
@Suite("Pick Color", .timeLimit(.minutes(1)))
struct PickTests {
    @Test func aPickClosesThePanelCopiesKeepsAndSaysWhat() async throws {
        let sampler = SimulatedColorSampler([try pick("#66CC99")])
        let harness = await readyHarness(sampler: sampler)
        let outcome = try await harness.run("pick")
        #expect(sampler.count == 1)
        #expect(harness.isClosed, "the panel closed before the sampler showed")
        #expect(outcome.kind == .close(hud: "Copied #66CC99"))
        #expect(harness.fakes.pasteboard.copiedTexts == ["#66CC99"])
        #expect(harness.huds == ["Copied #66CC99"])
        #expect(harness.historyHexes == ["#66CC99"])
        #expect(harness.feature.history.entries.first?.source == .picked)
        #expect(harness.fakes.pasteboard.pastedTexts.isEmpty)
        #expect(harness.issues.isEmpty)
    }

    @Test func escapeInTheSamplerChangesNothing() async throws {
        let sampler = SimulatedColorSampler([.cancelled])
        let harness = await readyHarness(sampler: sampler)
        let outcome = try await harness.run("pick")
        #expect(outcome.kind == .close(hud: nil))
        #expect(harness.isClosed)
        #expect(harness.fakes.pasteboard.copied.isEmpty)
        #expect(harness.huds.isEmpty && harness.toasts.isEmpty)
        #expect(harness.feature.history.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.historyFile.path), "nothing was written")
    }

    @Test func anUnreadableColorFailsWithAMessageAndKeepsNothing() async throws {
        let sampler = SimulatedColorSampler([.unreadable])
        let harness = await readyHarness(sampler: sampler)
        harness.throwsActionErrors = false
        try await harness.run("pick")
        #expect(harness.huds.map(\.title) == ["Could Not Read the Color"])
        #expect(harness.huds.first?.style == .failure)
        #expect(harness.fakes.pasteboard.copied.isEmpty && harness.feature.history.entries.isEmpty)

        // Components that are not numbers fail the same way.
        sampler.queue([.picked(PickedColor(space: .sRGB, red: .nan, green: 0, blue: 0))])
        try await harness.run("pick")
        #expect(harness.huds.map(\.title) == ["Could Not Read the Color", "Could Not Read the Color"])
        #expect(harness.feature.history.entries.isEmpty)
    }

    @Test func theDefaultFormatAndHexCaseApply() async throws {
        let sampler = SimulatedColorSampler([try pick("#66CC99"), try pick("#66CC99")])
        let harness = await readyHarness(sampler: sampler)
        harness.context.settings[ColorSettings.defaultFormat] = .rgb
        try await harness.run("pick")
        harness.context.settings[ColorSettings.defaultFormat] = .hex
        harness.context.settings[ColorSettings.hexCase] = .lowercase
        try await harness.run("pick")
        #expect(harness.fakes.pasteboard.copiedTexts == ["rgb(102 204 153)", "#66cc99"])
        #expect(harness.huds == ["Copied rgb(102 204 153)", "Copied #66cc99"])
        #expect(harness.feature.history.entries.count == 1, "the same color is kept once")
    }

    @Test func aDisplayP3PickIsConvertedAndTheDetailSaysItLiesOutsideSRGB() async throws {
        let sampler = SimulatedColorSampler([.picked(PickedColor(space: .displayP3, red: 1, green: 0, blue: 0))])
        let harness = await readyHarness(sampler: sampler)
        try await harness.run("pick")
        #expect(harness.fakes.pasteboard.copiedTexts == ["#FF0000"], "the formats show the nearest sRGB color")
        let entry = try #require(harness.feature.history.entries.first)
        #expect(entry.color.isOutsideSRGB)
        #expect(close(entry.color.red, 1.093_066) && close(entry.color.green, -0.226_742))

        try await harness.run("history")
        #expect(harness.rows.first?.accessories.first == .tag("Outside sRGB", color: .orange))
        let detail = try #require(try await harness.loadDetail())
        #expect(
            detail.metadata.contains(.label("Gamut", value: "Outside sRGB. Every format shows the nearest sRGB color."))
        )
        #expect(detail.metadata.contains(.label("Extended sRGB", value: "1.0931 -0.2267 -0.1501")))
        #expect(detail.metadata.contains(.label("Source", value: "Picked on screen")))
    }

    @Test func aPickInsideSRGBSaysNothingAboutGamut() async throws {
        let p3 = SimulatedColorSampler([
            .picked(PickedColor(space: .displayP3, red: 0.917_488, green: 0.200_287, blue: 0.138_561)),
            .picked(PickedColor(space: .extendedSRGB, red: 0.4, green: 0.2, blue: 0.6)),
        ])
        let harness = await readyHarness(sampler: p3)
        try await harness.run("pick")
        try await harness.run("pick")
        #expect(harness.fakes.pasteboard.copiedTexts == ["#FF0000", "#663399"])
        try await harness.run("history")
        for row in harness.rows {
            try harness.select(row.id)
            let detail = try #require(try await harness.loadDetail())
            #expect(
                !detail.metadata.contains { item in
                    if case .label("Gamut", _, _) = item { return true }
                    return false
                })
        }
    }

    @Test func pickStaysOutOfDeepLinksAndASecondStartIsDropped() async throws {
        let harness = await readyHarness()
        let command = try harness.command("pick")
        #expect(!command.allowsDeepLinks, "a web page must not start the sampler and change the clipboard")
        #expect(command.runPolicy == .dropWhileRunning)
        #expect(command.requires.isEmpty, "the sampler needs no permission")
        #expect(try harness.command("history").allowsDeepLinks)
    }

    @Test func theSimulatedSamplerIsWhatScenariosGet() async throws {
        // Without an override, a scenario run gets the simulated sampler, which shows nothing.
        let harness = FeatureHarness(ColorsFeature.self, environment: .scenario)
        #expect(harness.feature.sampler is SimulatedColorSampler)
        await harness.activate()
        await harness.feature.waitUntilReady()
        try await harness.run("pick")
        #expect(harness.fakes.pasteboard.copiedTexts == ["#663399"])
        #expect(ColorSamplerKey.isolated(harness.context) is SimulatedColorSampler)
    }
}
