import Foundation
import Kit
import KitTesting
import Testing

@testable import Clipboard

@Suite("Commands, settings and the services offered to others", .timeLimit(.minutes(1)))
@MainActor
struct CommandTests {
    @Test func theFeatureIsOnByDefaultAndDeclaresItsPermissions() async {
        let manifest = ClipboardHistoryFeature.manifest
        #expect(manifest.id == "clipboard")
        #expect(manifest.isEnabledByDefault)
        #expect(manifest.permissions.map(\.permission) == [.pasteboard, .accessibility])
        let clipboard = await ClipboardHarness()
        #expect(clipboard.harness.issues.isEmpty)
        #expect(
            clipboard.feature.commands.map(\.title) == [
                "Clipboard History", "Clear Clipboard History", "Clear Recent Clipboard History",
                "Pause Clipboard Recording",
            ])
    }

    @Test func clearHistoryAsksFirstAndKeepsPinnedItems() async throws {
        let clipboard = await ClipboardHarness()
        for text in ["pinned", "one", "two"] { try await clipboard.copy(text) }
        try await clipboard.store.setPinned(true, key: ClipboardHarness.textKey("pinned"))
        clipboard.harness.confirmationAnswer = false
        try await clipboard.harness.run("clear-history")
        #expect(try await clipboard.store.count() == 3)
        clipboard.harness.confirmationAnswer = true
        try await clipboard.harness.run("clear-history")
        #expect(clipboard.harness.confirmations.map(\.isDestructive) == [true, true])
        #expect(try await clipboard.keys() == [ClipboardHarness.textKey("pinned")])
        #expect(clipboard.harness.huds == [.success("Deleted 2 items")])
    }

    @Test func clearRecentDeletesOnlyThePeriodChosen() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("an hour ago")
        clipboard.advance(minutes: 50)
        try await clipboard.copy("ten minutes ago")
        clipboard.advance(minutes: 10)
        try await clipboard.copy("just now")
        try await clipboard.harness.run("clear-recent")
        #expect(try await clipboard.keys() == [ClipboardHarness.textKey("an hour ago")], "15 minutes by default")
        try await clipboard.copy("again")
        try await clipboard.harness.run("clear-recent", arguments: ["period": "1h"])
        #expect(try await clipboard.store.count() == 0)
        #expect(clipboard.harness.confirmations.count == 2)
        let period = try #require(try clipboard.harness.command("clear-recent").arguments.first)
        guard case .dropdown(let options) = period.kind else {
            Issue.record("the period is a dropdown")
            return
        }
        #expect(options.map(\.title) == ["Last 5 Minutes", "Last 15 Minutes", "Last Hour", "Last 24 Hours"])
    }

    @Test func theRecordingCommandPausesAndResumesAndRenamesItself() async throws {
        let clipboard = await ClipboardHarness()
        let before = clipboard.feature.declarations.generation
        try await clipboard.harness.run("toggle-recording")
        try await clipboard.harness.settle()
        #expect(clipboard.settings[ClipboardSettings.isPaused])
        #expect(!clipboard.feature.isMonitoring)
        #expect(clipboard.feature.declarations.generation > before)
        #expect(try clipboard.harness.command("toggle-recording").title == "Resume Clipboard Recording")
        #expect(clipboard.harness.huds.last == "Clipboard recording is paused")

        try await clipboard.harness.run("toggle-recording", launch: .hotkey)
        try await clipboard.harness.settle()
        #expect(!clipboard.settings[ClipboardSettings.isPaused])
        #expect(clipboard.feature.isMonitoring)
        #expect(try clipboard.harness.command("toggle-recording").title == "Pause Clipboard Recording")
    }

    @Test func theSettingsPaneSaysWhatIsStoredAndWhere() async throws {
        let clipboard = await ClipboardHarness()
        let pane = try #require(clipboard.feature.settingsPane)
        #expect(pane.sections.map(\.title) == ["Recording", "History", "Pasting", "Privacy"])
        let keys = pane.sections.flatMap(\.items).compactMap(\.control.key?.name)
        #expect(
            keys == [
                "paused", "retention", "maximumItems", "imageStorageMegabytes", "primaryAction", "movesUsedItemsToTop",
                "ignoredApps",
            ])
        let footer = try #require(pane.sections.last?.footer)
        #expect(footer.contains(clipboard.feature.storageFolderForDisplay))
        #expect(footer.contains("never sent anywhere"))
        let retention = try #require(pane.sections[1].items.first)
        guard case .picker(_, let options) = retention.control else {
            Issue.record("retention is a picker")
            return
        }
        #expect(options.map(\.title) == ["1 Day", "1 Week", "1 Month", "3 Months", "6 Months", "1 Year", "Forever"])
    }

    @Test func theSettingsButtonClearsHistoryAfterAsking() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("one")
        try await clipboard.harness.pressSettingsButton("Clear History")
        #expect(clipboard.harness.confirmations.count == 1)
        #expect(try await clipboard.store.count() == 0)
        #expect(clipboard.harness.toasts.last?.title == "Deleted 1 item")
    }

    @Test func theHistoryAnswersTheClipboardPlaceholderForOtherFeatures() async throws {
        let clipboard = await ClipboardHarness()
        guard case .clipboardHistory(let reader) = try #require(clipboard.feature.provides.first) else {
            Issue.record("the feature provides its history")
            return
        }
        #expect(await reader.text(offset: 0) == nil)
        try await clipboard.copy("oldest")
        try await clipboard.copy([.image(Samples.png(width: 2, height: 2), typeIdentifier: "public.png")])
        try await clipboard.copy("newest")
        #expect(await reader.text(offset: 0) == "newest")
        #expect(await reader.text(offset: 1) == "oldest", "images are skipped")
        #expect(await reader.text(offset: 2) == nil)
        #expect(await reader.text(offset: -1) == nil)
    }

    @Test func rootSearchOffersToPasteWhatWasJustCopiedForAShortWhile() async throws {
        let clipboard = await ClipboardHarness()
        #expect(try await clipboard.harness.suggestions().isEmpty)
        try await clipboard.copy("Fresh copy for the next app", from: ClipboardHarness.browser)
        let suggestion = try #require(try await clipboard.harness.suggestions().first)
        #expect(suggestion.row.title == "Paste \u{201C}Fresh copy for the next app\u{201D}")
        #expect(suggestion.row.subtitle == "Just copied from Example Browser")
        #expect(suggestion.row.memory == .never)
        #expect(suggestion.row.id == ClipboardHarness.id(ofText: "Fresh copy for the next app"))
        #expect(clipboard.harness.rootActions(for: suggestion.row).map(\.id) == ["paste", "copy"])

        try await clipboard.harness.performRoot("paste", on: suggestion.row)
        #expect(clipboard.pasteboard.pasted == [.text("Fresh copy for the next app")])

        clipboard.advance(minutes: 1)
        #expect(try await clipboard.harness.suggestions().count == 1)
        clipboard.advance(minutes: 1.5)
        #expect(try await clipboard.harness.suggestions().isEmpty, "two minutes after the copy it is gone")
        #expect(clipboard.harness.issues.isEmpty)
    }

    @Test func noSuggestionForADeletedItemOrWhilePaused() async throws {
        let clipboard = await ClipboardHarness()
        try await clipboard.copy("deleted soon")
        try await clipboard.store.delete(ClipboardHarness.textKey("deleted soon"))
        #expect(try await clipboard.harness.suggestions().isEmpty)
        try await clipboard.copy("before pausing")
        clipboard.settings[ClipboardSettings.isPaused] = true
        try await clipboard.harness.settle()
        #expect(try await clipboard.harness.suggestions().isEmpty)
    }
}
