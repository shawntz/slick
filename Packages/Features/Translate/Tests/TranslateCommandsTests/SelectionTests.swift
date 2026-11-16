import Foundation
import Kit
import KitTesting
import Testing

@testable import TranslateCommands

@Suite("Translate Selection", .timeLimit(.minutes(1)))
struct SelectionTests {
    @Test func theSelectedTextOpensTheSamePage() async throws {
        let harness = await readyHarness()
        harness.fakes.selection.selection = .text("Sept bateaux en papier")
        let outcome = try await harness.run("translate-selection")
        #expect(outcome.kind == .push)
        #expect(harness.fakes.selection.reads == 1)
        #expect(harness.page?.query == "Sept bateaux en papier")
        #expect(harness.titles == ["Seven paper boats"])
        #expect(harness.actions().first?.title == "Copy Translation")
        #expect(harness.issues.isEmpty)
    }

    @Test func aHotkeyRunReadsTheSelectionToo() async throws {
        let harness = await readyHarness()
        harness.fakes.selection.selection = .text("Bonjour")
        try await harness.run("translate-selection", launch: .hotkey)
        #expect(harness.titles == ["Good morning"])
    }

    @Test func withoutAccessibilityNothingIsReadAndTheHostAsks() async throws {
        let fakes = FakeServices(permissions: .denied)
        let harness = await readyHarness(fakes: fakes)
        harness.fakes.selection.selection = .text("Bonjour")
        await #expect(throws: HarnessError.permissionRequired([.accessibility])) {
            try await harness.run("translate-selection")
        }
        #expect(harness.fakes.selection.reads == 0)
        #expect(harness.fakes.permissions.requests.isEmpty, "only the user's Grant asks the system")
    }

    /// Access taken away after the host checked: the handler asks for the card instead of reading.
    @Test func accessGoneWhileRunningAsksForTheCardAgain() async throws {
        let harness = await readyHarness()
        harness.fakes.selection.selection = .text("Bonjour")
        let context = ActionContext(feature: harness.context, host: harness)
        harness.fakes.permissions.set(.accessibility, to: .denied)
        let outcome = try await TranslateFeature.translateSelection(context, pages: harness.feature.pages)
        #expect(outcome.kind == .needsPermission(.accessibility))
        #expect(harness.fakes.selection.reads == 0)
    }

    @Test func nothingSelectedSaysSoAndStays() async throws {
        let harness = await readyHarness()
        for selection: Selection? in [nil, .text("  \n"), .text("\u{200B}"), .files([URL(fileURLWithPath: "/tmp/x")])] {
            harness.fakes.selection.selection = selection
            let outcome = try await harness.run("translate-selection")
            #expect(outcome.kind == .keepOpen)
            #expect(harness.visibleToast?.title == "No Text Selected")
        }
        #expect(harness.pages.isEmpty)
    }

    @Test func aSelectionOverTheLimitIsRefused() async throws {
        let engine = RecordingEngine()
        let harness = await readyHarness(engine)
        harness.throwsActionErrors = false
        harness.fakes.selection.selection = .text(String(repeating: "a", count: TranslationText.maximumBytes + 1))
        try await harness.run("translate-selection")
        #expect(harness.toasts.last?.title == "Selection Too Long")
        #expect(harness.pages.isEmpty)
        #expect(engine.translations.isEmpty)
    }

    /// The app refuses a link to this command. Should one reach the handler, it reads nothing.
    @Test func aDeepLinkReadsNothing() async throws {
        let harness = await readyHarness()
        harness.fakes.selection.selection = .text("Bonjour")
        try await harness.run("translate-selection", launch: .deeplink)
        #expect(harness.fakes.selection.reads == 0)
        #expect(harness.page?.query == "")
    }
}
