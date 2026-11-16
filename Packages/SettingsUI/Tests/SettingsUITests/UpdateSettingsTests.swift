import Foundation
import Kit
import KitHosting
import Testing

@testable import SettingsUI

/// An updater in memory, as a release build would report it. Nothing is checked and nothing is
/// shown: ``checkNow()`` only counts.
@MainActor final class FakeUpdates: UpdateControl {
    let changes = ChangeSignal()
    var isAvailable = true
    var lastCheck: Date?
    var waitingVersion: String?
    var canCheckNow = true
    private(set) var checksAutomatically = false
    /// Every value passed to ``setChecksAutomatically(_:)``, in order.
    private(set) var choices: [Bool] = []
    private(set) var checks = 0

    func setChecksAutomatically(_ enabled: Bool) {
        choices.append(enabled)
        checksAutomatically = enabled
        changes.send()
    }

    func checkNow() {
        checks += 1
    }
}

/// The General pane's update section and onboarding's update switch.
@MainActor @Suite(.timeLimit(.minutes(1))) struct UpdateSettingsTests {
    @Test func aBuildFromSourceSaysGitUpdatesIt() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        #expect(!model.updatesAvailable)
        #expect(UpdateStrings.builtFromSource.contains("built from source"))
        #expect(UpdateStrings.builtFromSource.contains("git"))
    }

    @Test func theSwitchGoesThroughTheUpdaterAndStartsOff() {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = GeneralModel(context: bed.context())
        #expect(model.updatesAvailable)
        #expect(!model.checksForUpdates, "nothing is checked until the person agrees")
        model.checksForUpdates = true
        #expect(updates.choices == [true])
        #expect(model.checksForUpdates)
        model.checksForUpdates = false
        #expect(updates.choices == [true, false])
    }

    @Test func checkNowAsksTheUpdaterOnlyWhenPressed() {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = GeneralModel(context: bed.context())
        #expect(updates.checks == 0, "opening the pane checks nothing")
        #expect(model.canCheckForUpdates)
        model.checkForUpdatesNow()
        #expect(updates.checks == 1)
        updates.canCheckNow = false
        #expect(!model.canCheckForUpdates)
    }

    @Test func showsTheTimeOfTheLastCheck() async {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = GeneralModel(context: bed.context())
        #expect(model.lastCheckText == "Not checked yet")
        let moment = Date(timeIntervalSinceReferenceDate: 800_000_000)
        updates.lastCheck = moment
        updates.changes.send()
        #expect(model.lastCheckText == "Last checked " + moment.formatted(date: .abbreviated, time: .shortened))
    }

    /// An update a scheduled check found shows in the pane until the person looks, whether or not
    /// the menu bar item is shown, and its button opens the updater's window on it.
    @Test func anUpdateThatWaitsShowsInThePaneWithAButton() {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = GeneralModel(context: bed.context())
        #expect(model.waitingUpdateText == nil, "nothing waits")
        updates.waitingVersion = "0.2.0"
        updates.changes.send()
        #expect(model.waitingUpdateText == "\(Brand.name) 0.2.0 is available.")
        #expect(updates.checks == 0, "showing the line opens nothing")
        model.checkForUpdatesNow()
        #expect(updates.checks == 1)
        updates.waitingVersion = nil
        updates.changes.send()
        #expect(model.waitingUpdateText == nil, "the person looked")
        #expect(UpdateStrings.showUpdate.hasSuffix("…"), "it opens a window")
    }

    @Test func theSwitchSaysWhatIsSentAndToWhom() {
        #expect(UpdateStrings.automaticTitle == "Check for Updates Automatically")
        #expect(UpdateStrings.whatIsSent.contains("GitHub"))
        #expect(UpdateStrings.whatIsSent.contains("version"))
        #expect(UpdateStrings.whatIsSent.hasSuffix("."))
    }

    @Test func onboardingOffersTheSwitchOnAndFinishingStoresIt() async {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.offersUpdates)
        #expect(model.checksForUpdates, "the switch starts on")
        #expect(updates.choices.isEmpty, "showing the switch stores nothing")
        model.finish()
        #expect(updates.choices == [true])
        #expect(updates.checksAutomatically)
    }

    @Test func onboardingStoresTheSwitchTurnedOff() {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        let model = OnboardingModel(context: bed.context()) {}
        model.checksForUpdates = false
        model.finish()
        #expect(updates.choices == [false])
        #expect(!updates.checksAutomatically)
    }

    @Test func closingOnboardingBeforeTheEndStoresNothing() async {
        let bed = TestBed()
        let updates = FakeUpdates()
        bed.updates = updates
        var model: OnboardingModel? = OnboardingModel(context: bed.context()) {}
        await model?.next()
        model = nil
        #expect(updates.choices.isEmpty)
        #expect(!updates.checksAutomatically)
    }

    @Test func aBuildFromSourceHasNoSwitchInOnboarding() {
        let bed = TestBed()
        let model = OnboardingModel(context: bed.context()) {}
        #expect(!model.offersUpdates)
        model.finish()
        #expect(bed.general[HostSettings.onboardingDone])
    }
}
