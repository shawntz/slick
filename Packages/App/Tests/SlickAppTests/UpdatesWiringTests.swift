import AppKit
import Foundation
import Kit
import KitHosting
import KitTesting
import Root
import SettingsUI
import Testing
import Updates

@testable import SlickApp

/// An updater in memory, as a release build would report it. ``checkNow()`` only counts: no check
/// runs and no window opens.
@MainActor final class MenuUpdates: UpdateControl {
    let changes = ChangeSignal()
    var isAvailable = true
    var checksAutomatically = false
    var lastCheck: Date?
    var waitingVersion: String?
    var canCheckNow = true
    private(set) var checks = 0

    func setChecksAutomatically(_ enabled: Bool) {
        checksAutomatically = enabled
    }

    func checkNow() {
        checks += 1
    }
}

/// Where the updater comes from and what the menu bar menu offers. No Sparkle object is made: every
/// run here is outside the live launcher, and the menu is made without installing the item.
@Suite("Updates", .timeLimit(.minutes(1)))
struct UpdatesWiringTests {
    @Test(arguments: [RunEnvironment.selftest, .scenario, .bench])
    func everyRunButTheLiveLauncherGetsTheDoNothingUpdater(environment: RunEnvironment) async {
        let folder = CompositionTests.Folder()
        defer { folder.remove() }
        let assembly = Assembly(
            .init(environment: environment, dataRoot: folder.url, rootStorage: .inMemory, makesPanel: false))
        #expect(assembly.updates is NoUpdates)
        #expect(assembly.dependencies.updates is NoUpdates, "settings sees the same updater")
        await assembly.shutdown()
    }

    /// The template every bundle starts from turns automatic checks off, so Sparkle never asks its
    /// own question, and carries no feed and no key: only release packaging adds them. It also
    /// keeps Sparkle from offering silent automatic installs: an update downloads only when the
    /// person chooses to install it.
    @Test func theTemplateHasChecksOffAndNoFeed() throws {
        let plist = try InfoPlistTests.plist()
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false, "no silent download and install")
        #expect(plist["SUScheduledCheckInterval"] as? Int == 86_400, "once a day, as the switch says")
        #expect(plist[UpdateConfiguration.feedKey] == nil)
        #expect(plist[UpdateConfiguration.publicKeyKey] == nil)
        #expect(UpdateConfiguration(info: plist) == nil, "a bundle from the template gets the do-nothing updater")
    }

    @Test func aBuildThatUpdatesItselfOffersACheckAboveQuit() throws {
        let updates = MenuUpdates()
        let status = StatusItemController(
            settings: FakeSettings(), updates: updates, openLauncher: {}, openSettings: {})
        let menu = status.makeMenu()
        #expect(
            menu.items.map(\.title) == [
                AppStrings.openLauncher, AppStrings.settings, "", AppStrings.checkForUpdates, "", AppStrings.quit,
            ])
        #expect(AppStrings.checkForUpdates.hasSuffix("…"), "it opens a window")
        let check = menu.items[3]
        let target = try #require(check.target as? NSObject)
        let action = try #require(check.action)
        target.perform(action, with: check)
        #expect(updates.checks == 1)
        #expect(!status.isInstalled)
    }

    /// The updater asks whether the menu can offer an update a scheduled check found. The answer
    /// follows the menu bar item's switch, so with the item hidden Sparkle shows the update itself.
    @Test func theMenuRemindsOfAnUpdateOnlyWhileTheItemIsShown() {
        let settings = FakeSettings()
        let remindsInMenu = StatusItemController.remindsUpdates(settings: settings)
        #expect(remindsInMenu(), "the item shows by default")
        let general = HostSettings.settings(settings)
        general[HostSettings.showStatusItem] = false
        #expect(!remindsInMenu())
        general[HostSettings.showStatusItem] = true
        #expect(remindsInMenu())
    }

    @Test func aBuildFromSourceOffersNoCheck() {
        let status = StatusItemController(settings: FakeSettings(), openLauncher: {}, openSettings: {})
        #expect(!status.makeMenu().items.map(\.title).contains(AppStrings.checkForUpdates))
    }

    @Test func anUpdateAScheduledCheckFoundLeadsTheMenuUntilThePersonLooks() throws {
        let updates = MenuUpdates()
        let status = StatusItemController(
            settings: FakeSettings(), updates: updates, openLauncher: {}, openSettings: {})
        updates.waitingVersion = "0.2.0"
        let menu = status.makeMenu()
        #expect(menu.items.first?.title == "Update to \(Brand.name) 0.2.0…")
        #expect(menu.items[1].isSeparatorItem)
        let update = try #require(menu.items.first)
        let target = try #require(update.target as? NSObject)
        let action = try #require(update.action)
        target.perform(action, with: update)
        #expect(updates.checks == 1, "it opens the updater's window")

        updates.waitingVersion = nil
        #expect(status.makeMenu().items.first?.title == AppStrings.openLauncher)
    }

    @Test func theUpdateItemsWorkOnlyWhileTheUpdaterCanCheck() throws {
        let updates = MenuUpdates()
        let status = StatusItemController(
            settings: FakeSettings(), updates: updates, openLauncher: {}, openSettings: {})
        let menu = status.makeMenu()
        let check = try #require(menu.items.first { $0.title == AppStrings.checkForUpdates })
        let open = try #require(menu.items.first { $0.title == AppStrings.openLauncher })
        #expect(status.validateMenuItem(check))
        updates.canCheckNow = false
        #expect(!status.validateMenuItem(check))
        #expect(status.validateMenuItem(open), "the other items stay as they were")
    }
}
