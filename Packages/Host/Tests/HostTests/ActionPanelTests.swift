import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// The action panel, the host's own entries, cards and toasts.
@Suite("Panel: actions", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ActionPanelTests {
    @Test func aRowsPanelHasItsActionsUniversalActionsAndTheHostsEntries() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Notes")
        #expect(fixture.command("k"))
        #expect(fixture.panel.surface.overlay === fixture.panel.actionCard)
        #expect(
            fixture.panel.actionEntries.map(\.title) == [
                "Open", "Copy", "Reveal", "Show in Large Type", "Shout", "Add to Favorites", "Set Alias", "Set Hotkey",
                "Reset Ranking",
            ])
        let shout = fixture.panel.actionEntries[4]
        guard case .action(let action, let featureID, _) = shout.kind else {
            Issue.record("Shout is not an action")
            return
        }
        #expect(action.id == "relay.shout")
        #expect(featureID == "relay")
        #expect(shout.section == "Universal Actions")
        let card = fixture.panel.actionCard
        #expect(card.content.sections.map(\.title) == [nil, "Universal Actions", "Item"])
        #expect(card.content.sections[0].items[0].keys == ["↩"])
        #expect(card.content.sections[0].items[2].keys == ["⌘", "R"])

        #expect(card.content.sections[0].items[3].keys == ["⌘", "L"], "the row stands for text")

        card.selectItem(at: 4)
        let selected = try #require(card.selectedItem)
        card.onActivate?(selected)
        #expect(await waitUntil { fixture.runtime.relay.shouted == ["notes"] }, "the query is the selection as text")
        #expect(fixture.panel.surface.overlay == nil)
    }

    /// Clipboard history offers "Save as Snippet" on its rows, and Snippets offers the same title as
    /// a universal action for text. The panel shows it once, the row's own.
    @Test func aUniversalActionTheRowAlreadyOffersShowsOnce() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Notes")
        var target = try #require(fixture.panel.top.target)
        target.entries.append(
            ActionEntry(
                Action("Shout", id: "own-shout") { _ in .keepOpen }, featureID: target.featureID,
                context: target.context))
        let entries = fixture.panel.actionPanelEntries(for: target)
        let shouts = entries.filter { $0.title == "Shout" }
        #expect(shouts.count == 1)
        guard case .action(let action, _, _) = shouts.first?.kind else {
            Issue.record("Shout is not an action")
            return
        }
        #expect(action.id == "own-shout")
    }

    @Test func aCommandRowsPanelHasRunTheRowActionsAndADisableEntry() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Echo")
        fixture.command("k")
        #expect(
            fixture.panel.actionEntries.map(\.title) == [
                "Run Command", "Edit Echo", "Send to Relay", "Add to Favorites", "Set Alias", "Set Hotkey",
                "Reset Ranking", "Disable Command",
            ])
        #expect(fixture.command("1") == false, "row chords wait while a card shows")
        #expect(fixture.runtime.workbench.log.isEmpty)
        #expect(fixture.command("k"), "Command-K closes the action panel")
        #expect(fixture.panel.surface.overlay == nil)
        await fixture.runtime.runtime.preferences.setEnabled(false, feature: "relay")
        fixture.command("k")
        #expect(!fixture.panel.actionEntries.map(\.title).contains("Send to Relay"))
    }

    @Test func commandReturnRunsTheSecondaryAndShortcutsRunWithoutThePanel() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Example")
        fixture.press(.submit([.command]))
        #expect(await waitUntil { fixture.copied.value == [SampleRows.editor.id] })
        #expect(fixture.root.calls.contains(.didRun(SampleRows.editor.id, .root)))
        #expect(fixture.panel.surface.overlay == nil)
    }

    @Test func favoritesRankingAndDisableWorkFromThePanel() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let preferences = fixture.runtime.runtime.preferences
        fixture.type("Example")
        run(fixture, "Add to Favorites")
        #expect(preferences.favorites == [SampleRows.editor.id])
        #expect(fixture.panel.surface.actionBar.toast == ActionBarToast(.success, "Added to Favorites"))
        run(fixture, "Remove from Favorites")
        #expect(preferences.favorites.isEmpty)
        run(fixture, "Reset Ranking")
        #expect(fixture.root.calls.contains(.forget(SampleRows.editor.id)))
        fixture.type("Plain")
        run(fixture, "Disable Command")
        #expect(preferences.isEnabled(command: SampleRows.plain.id) == false)
    }

    @Test func aliasAndHotkeyArePromptedInTheSearchField() async {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let preferences = fixture.runtime.runtime.preferences
        fixture.type("Plain")
        run(fixture, "Set Alias")
        #expect(fixture.panel.stack.count == 2)
        #expect(fixture.field.placeholder == "Type an alias, then press Return")
        fixture.type("pl")
        fixture.press(.submit([]))
        #expect(preferences.aliases[SampleRows.plain.id] == "pl")
        #expect(fixture.panel.stack.count == 1)

        run(fixture, "Set Hotkey")
        fixture.type("not a key")
        fixture.press(.submit([]))
        #expect(fixture.panel.stack.count == 2, "a bad combination keeps the prompt open")
        fixture.type("opt+ctrl+p")
        fixture.press(.submit([]))
        #expect(preferences.hotkeys[SampleRows.plain.id] == KeyCombo(.p, [.option, .control]))
        #expect(fixture.runtime.fakes.hotkeys.registered[HostPreferences.bindingID(for: SampleRows.plain.id)] != nil)
    }

    @Test func setHotkeyRecordsAChord() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let preferences = fixture.runtime.runtime.preferences
        fixture.type("Plain")
        run(fixture, "Set Hotkey")
        let form = try #require(fixture.panel.top.contentView.child as? FormView)
        #expect(form.content.items.first?.kind == .hotkey(placeholder: "Record a shortcut"))
        form.onChange?("hotkey", .hotkey(KeyChord("j", [.command, .option])))
        #expect(preferences.hotkeys[SampleRows.plain.id] == KeyCombo(.j, [.option, .command]))
        #expect(fixture.panel.stack.count == 1)
        #expect(fixture.panel.surface.actionBar.toast?.text == "Hotkey Saved")
    }

    @Test func theConfirmCardAsksInsideThePanel() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        let card = try #require(fixture.panel.pendingCard)
        #expect(fixture.panel.surface.overlay === card)
        #expect(card.content.title == "Clear everything?")
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(fixture.runtime.workbench.log == ["clear"])
        #expect(fixture.panel.surface.overlay == nil)
    }

    @Test func dontAskAgainStopsTheQuestion() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let pipeline = fixture.runtime.runtime.pipeline
        let preferences = fixture.runtime.runtime.preferences

        // Unchecked: the next run asks again.
        var run = pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        var card = try #require(fixture.panel.pendingCard)
        #expect(card.content.suppressionTitle == "Don't ask again")
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(!preferences.isConfirmationSuppressed("workbench.clear"))

        // Checked and cancelled: nothing is stored.
        run = pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        card = try #require(fixture.panel.pendingCard)
        card.keyDown(with: PanelFixture.spaceKey())
        #expect(card.isSuppressionChecked)
        card.cancelOperation(nil)
        await run.value
        #expect(!preferences.isConfirmationSuppressed("workbench.clear"))

        // Checked and confirmed: stored, and the next run goes ahead without a card.
        run = pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        card = try #require(fixture.panel.pendingCard)
        card.keyDown(with: PanelFixture.spaceKey())
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(preferences.isConfirmationSuppressed("workbench.clear"))
        await pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root).value
        #expect(fixture.panel.pendingCard == nil)
        #expect(fixture.runtime.workbench.log == ["clear", "clear", "clear"])
    }

    @Test func aHotkeyLaunchOpensThePanelToConfirm() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("clear"), launch: .hotkey)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(fixture.panel.isPanelVisible)
        fixture.panel.dismiss()
        await run.value
        #expect(fixture.runtime.workbench.log.isEmpty, "a dismissed panel answers no")
    }

    @Test func thePermissionCardExplainsAndAsksOnlyAfterGrant() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.fakes.permissions.set(.accessibility, to: .notDetermined)
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        let card = try #require(fixture.panel.pendingCard)
        #expect(card.content.title == "Workbench Needs Accessibility")
        #expect(card.content.message == "Move the windows you pick.")
        #expect(fixture.runtime.fakes.permissions.requests.isEmpty)
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(fixture.runtime.fakes.permissions.requests == [.accessibility])
        #expect(fixture.runtime.workbench.log == ["guarded"])
    }

    @Test func toastsShowInTheBarAndAsHUDsWhenClosed() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let pipeline = fixture.runtime.runtime.pipeline
        await pipeline.runCommand(RuntimeFixture.command("toast"), launch: .root).value
        #expect(fixture.panel.surface.actionBar.toast == ActionBarToast(.info, "Saved", buttonTitle: "Undo"))
        // The bar's button runs the toast's action.
        fixture.panel.surface.actionBar.onToastButton?()
        #expect(await waitUntil { fixture.runtime.workbench.log == ["undo"] })
        fixture.command("k")
        #expect(fixture.panel.actionEntries.first?.title == "Undo")
        let card = fixture.panel.actionCard
        card.onActivate?(try #require(card.selectedItem))
        #expect(await waitUntil { fixture.runtime.workbench.log == ["undo", "undo"] })

        await pipeline.runCommand(RuntimeFixture.command("fail"), launch: .root).value
        #expect(
            fixture.panel.surface.actionBar.toast
                == ActionBarToast(.failure, "Could not reach the server: Timed out"), "a later toast replaces")
        fixture.panel.dismiss()
        #expect(fixture.panel.surface.actionBar.toast == nil)
        await pipeline.runCommand(RuntimeFixture.command("fail"), launch: .hotkey).value
        #expect(fixture.hud.shown == [.failure("Could not reach the server")])
    }

    private func run(_ fixture: PanelFixture, _ title: String) {
        fixture.command("k")
        guard let index = fixture.panel.actionEntries.firstIndex(where: { $0.title == title }) else {
            Issue.record("no entry \(title)")
            return
        }
        fixture.panel.actionCard.selectItem(at: index)
        guard let item = fixture.panel.actionCard.selectedItem else { return }
        fixture.panel.actionCard.onActivate?(item)
    }
}
