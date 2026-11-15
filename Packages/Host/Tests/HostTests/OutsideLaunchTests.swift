import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Runs that start while the panel is closed, from a hotkey, a link or a keyword typed in another
/// app. Every question opens the panel and asks there.
@Suite("Panel: runs started outside the panel", .serialized, .timeLimit(.minutes(1)))
@MainActor struct OutsideLaunchTests {
    nonisolated static let launches: [LaunchSource] = [.hotkey, .deeplink, .textExpansion]

    @Test(arguments: launches)
    func aDeclaredConfirmationOpensThePanelAndAsks(launch: LaunchSource) async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("clear"), launch: launch)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(fixture.panel.isPanelVisible)
        #expect(fixture.runtime.workbench.log.isEmpty, "nothing runs before the answer")
        let card = try #require(fixture.panel.pendingCard)
        #expect(card.content.title == "Clear everything?")
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(fixture.runtime.workbench.log == ["clear"])
        #expect(fixture.runtime.workbench.launches == [launch])
    }

    @Test(arguments: launches)
    func aFeaturesOwnConfirmationOpensThePanelAndAsks(launch: LaunchSource) async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("eject"), launch: launch)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(fixture.panel.isPanelVisible)
        let card = try #require(fixture.panel.pendingCard)
        #expect(card.content.title == "Eject 2 disks?")
        #expect(card.content.suppressionTitle == "Don't ask again")
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(fixture.runtime.workbench.log == ["eject"])
        #expect(fixture.runtime.workbench.launches == [launch])
    }

    @Test(arguments: launches)
    func aMissingPermissionOpensThePanelOnItsCard(launch: LaunchSource) async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        fixture.runtime.fakes.permissions.set(.accessibility, to: .notDetermined)
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("guarded"), launch: launch)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(fixture.panel.isPanelVisible)
        let card = try #require(fixture.panel.pendingCard)
        #expect(card.content.title == "Workbench needs Accessibility")
        #expect(fixture.runtime.fakes.permissions.requests.isEmpty, "the system is asked only after the button")
        card.keyDown(with: PanelFixture.returnKey())
        await run.value
        #expect(fixture.runtime.fakes.permissions.requests == [.accessibility])
        #expect(fixture.runtime.workbench.log == ["guarded"])
        #expect(fixture.runtime.workbench.launches == [launch])
    }

    @Test func cancellingAQuestionThatOpenedThePanelClosesItAgain() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("clear"), launch: .hotkey)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        try #require(fixture.panel.pendingCard).cancelOperation(nil)
        await run.value
        #expect(!fixture.panel.isPanelVisible)
        #expect(fixture.runtime.workbench.log.isEmpty)
    }

    @Test func cancellingAQuestionInTheOpenPanelKeepsItOpen() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let run = fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("clear"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        try #require(fixture.panel.pendingCard).cancelOperation(nil)
        await run.value
        #expect(fixture.panel.isPanelVisible)
    }

    /// System Settings takes key focus, which would close the panel with its toast unread. The
    /// panel closes first and a HUD says what to allow; the run goes ahead once it is allowed.
    @Test func aGrantInSystemSettingsClosesThePanelAndSaysWhatToAllow() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let pipeline = fixture.runtime.runtime.pipeline
        let permissions = fixture.runtime.fakes.permissions
        permissions.set(.accessibility, to: .notDetermined)
        permissions.answer = .denied
        let run = pipeline.runCommand(RuntimeFixture.command("guarded"), launch: .root)
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        try #require(fixture.panel.pendingCard).keyDown(with: PanelFixture.returnKey())
        #expect(await waitUntil { pipeline.grantWaitCount == 1 })
        #expect(!fixture.panel.isPanelVisible)
        #expect(permissions.openedSettings == [.accessibility])
        #expect(fixture.hud.shown == [.failure("Allow Accessibility in System Settings")])
        permissions.set(.accessibility, to: .granted)
        await run.value
        #expect(fixture.runtime.workbench.log == ["guarded"])
    }

    // MARK: Text expansion

    /// As App's hook does for `ExpansionResult.runCommand`: the command runs with launch
    /// textExpansion and opens the panel on its form, and the form pastes into the app in front.
    @Test func aKeywordWithBlanksOpensItsFormAndPastes() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        await fixture.runtime.runtime.pipeline.runCommand(
            RuntimeFixture.command("fill"), arguments: ["snippet": "greeting"], launch: .textExpansion
        ).value
        #expect(fixture.panel.isPanelVisible)
        let form = try #require(fixture.panel.top as? FormPageController)
        #expect(form.title == "Fill In")
        #expect(fixture.runtime.workbench.launches == [.textExpansion])
        #expect(fixture.runtime.workbench.arguments == [CommandArguments(["snippet": "greeting"])])
        form.fill("name", .text("friend"))
        form.submit()
        #expect(await waitUntil { !fixture.panel.isPanelVisible })
        #expect(fixture.runtime.fakes.pasteboard.pasted == [.text("Hello friend")])
    }

    @Test func aKeywordWithoutBlanksPastesWithoutOpeningThePanel() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        await fixture.runtime.runtime.pipeline.runCommand(
            RuntimeFixture.command("fill"), arguments: ["snippet": "plain"], launch: .textExpansion
        ).value
        #expect(!fixture.panel.isPanelVisible)
        #expect(fixture.runtime.fakes.pasteboard.pasted == [.text("Plain text")])
        #expect(fixture.hud.shown.isEmpty)
    }

    // MARK: Links

    /// A command that stays out of deep links runs from a hotkey but never from a link.
    @Test func aLinkNeverRunsACommandThatStaysOutOfLinks() async {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        let pipeline = fixture.runtime.runtime.pipeline
        await pipeline.runCommand(RuntimeFixture.command("act-now"), launch: .deeplink).value
        #expect(fixture.runtime.workbench.log.isEmpty)
        #expect(fixture.hud.shown == [.failure("This Command Cannot Run from a Link")])
        await pipeline.runCommand(RuntimeFixture.command("act-now"), launch: .hotkey).value
        #expect(fixture.runtime.workbench.log == ["act-now"])
    }

    // MARK: Arguments

    @Test func aCommandRowsActionsGetTheTypedArguments() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.type("Echo")
        fixture.field.arguments = [
            QueryArgument(placeholder: "text", value: "hello"), QueryArgument(placeholder: "mode", value: "loud"),
        ]
        fixture.command("k")
        let index = try #require(fixture.panel.actionEntries.firstIndex { $0.title == "Edit Echo" })
        fixture.panel.actionCard.selectItem(at: index)
        fixture.panel.actionCard.onActivate?(try #require(fixture.panel.actionCard.selectedItem))
        #expect(await waitUntil { fixture.runtime.workbench.log == ["edit-echo"] })
        #expect(fixture.runtime.workbench.arguments == [CommandArguments(["text": "hello", "mode": "loud"])])
    }

    /// An action hands over to a command whose required argument it does not have: the search
    /// field asks for it, and Return runs the command with it and with what the action passed.
    @Test func aHandOffWithoutARequiredArgumentAsksInTheSearchField() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        await fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("ask-echo"), launch: .root).value
        #expect(fixture.runtime.workbench.log.isEmpty)
        let page = try #require(fixture.panel.top as? ArgumentsPageController)
        #expect(page.title == "Echo")
        #expect(fixture.field.arguments.map(\.placeholder) == ["text", "mode"])
        #expect(fixture.field.arguments.map(\.value) == ["", "plain"])
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Run Command")

        fixture.press(.submit([]))
        #expect(fixture.panel.top === page, "Return with the required argument empty keeps asking")
        fixture.field.arguments = [
            QueryArgument(placeholder: "text", value: "typed"), QueryArgument(placeholder: "mode", value: "plain"),
        ]
        fixture.press(.submit([]))
        #expect(await waitUntil { fixture.runtime.workbench.log == ["echo"] })
        #expect(
            fixture.runtime.workbench.arguments == [
                CommandArguments(["text": "typed", "mode": "plain", "kept": "yes"])
            ])
        #expect(fixture.runtime.workbench.launches == [.command])
        #expect(fixture.panel.top === fixture.panel.rootPage)
    }

    @Test func escapeLeavesTheArgumentsUnaskedAndRunsNothing() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        await fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("ask-echo"), launch: .root).value
        #expect(fixture.panel.top is ArgumentsPageController)
        fixture.press(.cancel([]))
        #expect(fixture.panel.top === fixture.panel.rootPage)
        #expect(fixture.runtime.workbench.log.isEmpty)
    }

    @Test func aHotkeyForACommandWithBlanksOpensThePanelToAskForThem() async throws {
        let fixture = await PanelFixture.make(summon: false)
        defer { fixture.close() }
        await fixture.runtime.runtime.pipeline.runCommand(RuntimeFixture.command("echo"), launch: .hotkey).value
        #expect(fixture.panel.isPanelVisible)
        let page = try #require(fixture.panel.top as? ArgumentsPageController)
        #expect(page.launch == .hotkey)
        #expect(fixture.hud.shown.isEmpty, "asking is not a failure")
    }
}
