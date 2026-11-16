import Foundation
import Kit
import KitHosting
import Sparkle
import os

/// The live launcher's updater: Sparkle's updater with its standard window.
///
/// Only ``Updates/make(environment:bundle:remindsInMenu:)`` makes one, for the live launcher
/// started from a bundle with a feed address and a public key. It never runs in a test.
///
/// - Automatic checks start off, because the Info.plist sets `SUEnableAutomaticChecks` to false.
///   So Sparkle never asks its own question, and nothing is checked until the person turns the
///   switch on in onboarding or in the General pane.
/// - A check the person asks for shows Sparkle's standard window.
/// - While the menu bar item is shown, a scheduled check opens no window and takes no focus.
///   Sparkle's gentle reminders hand the update to ``UpdateReminder``, and the menu bar menu offers
///   it until the person looks. With the item hidden, Sparkle shows its window as for any
///   background app. The General pane names the waiting update either way.
/// - No system profile is sent: no profile key is allowed and no feed parameter is added, so the
///   request for the feed is all Sparkle sends.
/// - The feed is the one Info.plist names. The delegate hands it to Sparkle, which then ignores a
///   feed address written into the app's user defaults.
final class SparkleUpdates: UpdateControl {
    let changes = ChangeSignal()
    private let delegate: SparkleDelegate
    private let driver: SPUStandardUserDriver
    private let updater: SPUUpdater
    private(set) var isAvailable = false
    private let log = KitLog.logger(category: "updates")

    /// `remindsInMenu` says whether the menu bar menu can offer an update a scheduled check found,
    /// which it can while the menu bar item is shown.
    init(bundle: Bundle, configuration: UpdateConfiguration, remindsInMenu: @escaping @MainActor () -> Bool) {
        // Sparkle holds both delegates and the user driver weakly, so this object keeps them.
        let delegate = SparkleDelegate(changes: changes, configuration: configuration, remindsInMenu: remindsInMenu)
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: delegate)
        self.delegate = delegate
        self.driver = driver
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        do {
            try updater.start()
            isAvailable = true
        } catch {
            // A bundle Sparkle finds misconfigured gets no updater rather than Sparkle's alert.
            log.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Profiling is off unless someone turned it on in the app's defaults. Turn it off again.
        if updater.sendsSystemProfile { updater.sendsSystemProfile = false }
        log.info("updates from \(configuration.feed.absoluteString, privacy: .public)")
    }

    var checksAutomatically: Bool {
        isAvailable && updater.automaticallyChecksForUpdates
    }

    func setChecksAutomatically(_ enabled: Bool) {
        guard isAvailable, updater.automaticallyChecksForUpdates != enabled else { return }
        // Sparkle stores the choice in the app's defaults and resets its schedule after a short delay.
        updater.automaticallyChecksForUpdates = enabled
        changes.send()
    }

    var lastCheck: Date? {
        isAvailable ? updater.lastUpdateCheckDate : nil
    }

    var waitingVersion: String? {
        delegate.reminder.waitingVersion
    }

    var canCheckNow: Bool {
        isAvailable && updater.canCheckForUpdates
    }

    func checkNow() {
        guard isAvailable else { return }
        // Brings an update Sparkle already holds to the front, or checks and shows the result.
        updater.checkForUpdates()
    }
}

/// The delegate of Sparkle's updater and of its standard user driver. Sparkle calls both on the main
/// thread.
final class SparkleDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let changes: ChangeSignal
    private let configuration: UpdateConfiguration
    private let remindsInMenu: @MainActor () -> Bool
    private(set) var reminder = UpdateReminder()

    init(changes: ChangeSignal, configuration: UpdateConfiguration, remindsInMenu: @escaping @MainActor () -> Bool) {
        self.changes = changes
        self.configuration = configuration
        self.remindsInMenu = remindsInMenu
    }

    // MARK: Where the request goes, and what it carries

    /// The feed Info.plist names, already checked to be https. Sparkle asks its delegate first, so a
    /// feed address that another process writes into the app's user defaults is never used.
    var pinnedFeed: String {
        configuration.feed.absoluteString
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        pinnedFeed
    }

    /// No system profile key may be sent, even if profiling were turned on.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    /// No parameter is added to the feed's address.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }

    /// A check ended, so the time of the last check may have changed.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        changes.send()
    }

    // MARK: Gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Asked for scheduled checks only. Sparkle's header asks for no side effect here. Sparkle shows
    /// the update itself only when the menu bar menu cannot offer it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        UpdateReminder.sparkleShowsScheduledUpdate(remindsInMenu: remindsInMenu())
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        reminder.willShow(version: update.displayVersionString, userInitiated: state.userInitiated)
        changes.send()
    }

    /// The person brought the update to the front, or chose to install, skip or put it off.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        reminder.clear()
        changes.send()
    }

    func standardUserDriverWillFinishUpdateSession() {
        reminder.clear()
        changes.send()
    }

    /// The appcast carries no link to a version history, so Sparkle offers none.
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        false
    }
}
