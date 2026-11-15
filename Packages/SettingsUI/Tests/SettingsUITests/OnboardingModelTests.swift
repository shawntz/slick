import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct OnboardingModelTests {
    @Test func walksEveryStepAndFinishes() {
        let bed = TestBed(permissions: .notDetermined)
        var finished = 0
        let model = OnboardingModel(context: bed.context()) { finished += 1 }
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
        model.next()
        #expect(model.step == .hotkey)
        model.next()
        #expect(model.step == .permissions)
        model.back()
        #expect(model.step == .hotkey)
        model.next()
        model.next()
        #expect(model.step == .theme)
        model.next()
        #expect(model.step == .done)
        #expect(!bed.general[HostSettings.onboardingDone])
        model.finish()
        #expect(bed.general[HostSettings.onboardingDone])
        #expect(finished == 1)
        #expect(OnboardingController.isNeeded(bed.fakes.settings) == false)
    }

    @Test func skipsThePermissionsStepWhenNothingNeedsOne() async {
        let bed = TestBed(permissions: .notDetermined)
        await bed.preferences.setEnabled(false, feature: "sample")
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.permissionItems.isEmpty)
        model.next()
        model.next()
        #expect(model.step == .theme)
        model.back()
        #expect(model.step == .hotkey)
    }

    @Test func listsOnlyEnabledFeaturesPermissionsAndNeverAsksUnasked() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        model.next()
        model.next()
        let items = model.permissionItems
        #expect(items.map(\.permission) == [.accessibility, .inputMonitoring])
        #expect(items[0].reasons.map(\.feature) == ["Sample Tools"])
        #expect(bed.fakes.permissions.requests.isEmpty)

        model.skip(.accessibility)
        #expect(model.permissionItems[0].isSkipped)
        #expect(bed.fakes.permissions.requests.isEmpty)

        await model.allow(.inputMonitoring)
        #expect(bed.fakes.permissions.requests == [.inputMonitoring])
        #expect(model.permissionItems[1].status == .granted)
        model.next()
        model.next()
        model.finish()
        #expect(bed.fakes.permissions.requests == [.inputMonitoring])
    }

    @Test func hotkeyStepChecksConflictsAndNamesSpotlight() {
        let bed = TestBed()
        bed.preferences.addConflict(
            HotkeyConflict(owner: "Spotlight", canOverride: false), for: OnboardingModel.spotlightCombo)
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.spotlightNote.contains("Spotlight keeps ⌘Space"))
        #expect(model.hotkey.combo == KeyCombo(.space, .option))
        model.hotkey.beginRecording()
        model.hotkey.handle(key: .space, modifiers: .command)
        guard case .blocked = model.hotkey.state else {
            Issue.record("Command-Space was accepted")
            return
        }
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.space, .option))
        model.hotkey.beginRecording()
        model.hotkey.handle(key: .space, modifiers: [.command, .shift])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.space, [.command, .shift]))
    }

    @Test func picksATheme() {
        let bed = TestBed()
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.themes.count == ThemeStore.builtInThemes.count)
        model.selectTheme("Ember")
        #expect(model.selectedTheme == "Ember")
        #expect(bed.general[HostSettings.themeName] == "Ember")
        model.selectTheme("Missing")
        #expect(model.selectedTheme == "Ember")
    }
}
