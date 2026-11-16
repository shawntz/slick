import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// A feature's own question belongs to its run. When the run is cancelled, as when the user
/// switches the feature off, the card goes and the question counts as answered no, so a button
/// that can no longer do anything never stays on screen.
@Suite("Panel: a question whose run is cancelled", .serialized, .timeLimit(.minutes(1)))
@MainActor struct QuestionCancelTests {
    @Test func switchingTheFeatureOffTakesItsQuestionDownAndClosesThePanelItOpened() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("eject"), launch: .hotkey)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(fixture.panel.isPanelVisible)

        await fixture.runtime.runtime.preferences.setEnabled(false, feature: "workbench")
        #expect(await waitUntil { fixture.panel.pendingCard == nil })
        #expect(fixture.panel.surface.overlay == nil)
        #expect(await waitUntil { fixture.panel.runtime.pipeline.activeRunCount == 0 })
        #expect(!fixture.panel.isPanelVisible, "the panel the question opened closes again")
        #expect(fixture.runtime.workbench.log.isEmpty)
        if fixture.panel.pendingCard == nil { await run.value }
    }

    @Test func inThePanelTheUserOpenedTheQuestionGoesAndThePanelStays() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("eject"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })

        await fixture.runtime.runtime.preferences.setEnabled(false, feature: "workbench")
        #expect(await waitUntil { fixture.panel.pendingCard == nil })
        #expect(fixture.panel.surface.overlay == nil)
        #expect(fixture.panel.isPanelVisible)
        #expect(fixture.runtime.workbench.log.isEmpty)
        if fixture.panel.pendingCard == nil { await run.value }
    }
}
