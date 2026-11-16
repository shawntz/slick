import Foundation
import Kit
import Sparkle
import Testing

@testable import Updates

/// How a scheduled check's update waits in the menu until the person looks, and how the delegate
/// meets Sparkle's header. No updater is made or started. The one Sparkle object made here is an
/// empty appcast item, which Sparkle offers for tests.
@Suite(.timeLimit(.minutes(1))) struct ReminderTests {
    static let configuration = UpdateConfiguration(info: UpdatesFactoryTests.releaseInfo)!

    @Test func sparkleShowsAScheduledUpdateOnlyWhenTheMenuCannotOfferIt() {
        #expect(!UpdateReminder.sparkleShowsScheduledUpdate(remindsInMenu: true), "the menu leads with it instead")
        #expect(UpdateReminder.sparkleShowsScheduledUpdate(remindsInMenu: false), "nothing else would show it")
    }

    /// The delegate asks whether the menu bar item is shown each time Sparkle asks, because the
    /// person can hide or show the item at any moment.
    @Test func theDelegateAsksTheMenuEachTime() {
        final class MenuBarItem { var shown = true }
        let item = MenuBarItem()
        let delegate = SparkleDelegate(changes: ChangeSignal(), configuration: Self.configuration) { item.shown }
        let update = SUAppcastItem.empty()
        #expect(!delegate.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: false))
        #expect(!delegate.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
        item.shown = false
        #expect(delegate.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: false))
        #expect(delegate.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
    }

    /// Sparkle reads a feed address from the app's user defaults before Info.plist, unless its
    /// delegate names one. The delegate names the one Info.plist carries.
    @Test func theDelegatePinsTheFeedInfoPlistNames() {
        let delegate = SparkleDelegate(changes: ChangeSignal(), configuration: Self.configuration) { true }
        #expect(delegate.pinnedFeed == UpdatesFactoryTests.feed)
    }

    @Test func anUpdateFromAScheduledCheckWaitsWithItsVersion() {
        var reminder = UpdateReminder()
        #expect(reminder.waitingVersion == nil)
        reminder.willShow(version: "0.2.0", userInitiated: false)
        #expect(reminder.waitingVersion == "0.2.0")
    }

    @Test func anUpdateThePersonAskedForDoesNotWait() {
        var reminder = UpdateReminder()
        reminder.willShow(version: "0.2.0", userInitiated: false)
        reminder.willShow(version: "0.2.0", userInitiated: true)
        #expect(reminder.waitingVersion == nil)
    }

    @Test func lookingAtItOrEndingTheSessionLetsGo() {
        var reminder = UpdateReminder()
        reminder.willShow(version: "0.2.0", userInitiated: false)
        reminder.clear()
        #expect(reminder.waitingVersion == nil)
    }

    @Test func theDelegateTakesOnGentleRemindersAndStartsWithNothingWaiting() {
        let delegate = SparkleDelegate(changes: ChangeSignal(), configuration: Self.configuration) { true }
        #expect(delegate.supportsGentleScheduledUpdateReminders)
        #expect(delegate.reminder.waitingVersion == nil)
    }

    /// Sparkle asks for each optional method by its selector before calling it, so a Swift name that
    /// misses the header's selector would be skipped without an error. These are the selectors in
    /// SPUUpdaterDelegate.h and SPUStandardUserDriverDelegate.h of Sparkle 2.9.6.
    @Test(arguments: [
        "feedURLStringForUpdater:",
        "allowedSystemProfileKeysForUpdater:",
        "feedParametersForUpdater:sendingSystemProfile:",
        "updater:didFinishUpdateCycleForUpdateCheck:error:",
        "supportsGentleScheduledUpdateReminders",
        "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
        "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
        "standardUserDriverDidReceiveUserAttentionForUpdate:",
        "standardUserDriverWillFinishUpdateSession",
        "standardUserDriverShouldShowVersionHistoryForAppcastItem:",
    ])
    func theDelegateAnswersToTheHeadersSelector(selector: String) {
        let delegate = SparkleDelegate(changes: ChangeSignal(), configuration: Self.configuration) { true }
        #expect(delegate.responds(to: NSSelectorFromString(selector)))
    }
}
