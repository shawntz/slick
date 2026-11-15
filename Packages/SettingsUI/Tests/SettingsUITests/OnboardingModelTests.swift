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
        #expect(model.step == .features)
        model.next()
        #expect(model.step == .permissions)
        model.back()
        #expect(model.step == .features)
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
        #expect(model.step == .features)
        model.next()
        #expect(model.step == .theme)
        model.back()
        #expect(model.step == .features)
    }

    @Test func skipsTheFeaturesStepWhenEveryFeatureIsOnByDefault() {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.entries.removeAll { $0.id == "helper" }
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.optionalFeatures.isEmpty)
        model.next()
        model.next()
        #expect(model.step == .permissions)
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

    @Test func theHotkeyStepLeadsWithCommandSpace() {
        let bed = TestBed()
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.hotkey.combo == KeyCombo(.space, .command))
        #expect(model.hotkeyGuide == .none)
    }

    @Test func theHotkeyStepStoresCommandSpaceWhileSpotlightHoldsIt() {
        let bed = TestBed()
        bed.general[HostSettings.launcherHotkey] = nil
        bed.preferences.addSystemShortcut(SpotlightShortcutGuide.combo)
        let model = OnboardingModel(context: bed.context()) {}
        model.hotkey.beginRecording()
        model.hotkey.handle(key: .space, modifiers: .command)
        guard case .held(let combo, let holders) = model.hotkey.state else {
            Issue.record("Command-Space was not stored: \(model.hotkey.state)")
            return
        }
        #expect(combo == SpotlightShortcutGuide.combo)
        #expect(holders.map(\.owner) == ["Spotlight"])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.space, .command))
    }

    @Test func theHotkeyStepExplainsTheWaitAndTurnsGreenWhenItEnds() async {
        let bed = TestBed()
        bed.hotkeyStatus.startWaiting()
        let model = OnboardingModel(context: bed.context()) {}
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight")
        #expect(model.hotkeyGuide == .waiting(wait))
        #expect(wait.isSpotlight)
        let note = SpotlightShortcutGuide.waitingNote(wait)
        #expect(note.hasPrefix("Spotlight holds ⌘Space"))
        #expect(note.contains("Turn off Spotlight's shortcut in System Settings"))
        #expect(SpotlightShortcutGuide.steps.count == 3)

        model.openKeyboardSettings()
        #expect(await eventually { bed.fakes.workspace.opened == [SpotlightShortcutGuide.keyboardSettingsURL] })

        bed.hotkeyStatus.bindWaited()
        #expect(await eventually { model.hotkeyGuide == .freed(KeyCombo(.space, .command)) })
        #expect(SpotlightShortcutGuide.freedLine(KeyCombo(.space, .command)) == "⌘Space opens \(Brand.name) now.")
    }

    @Test func theGuideNeverSuggestsOptionSpace() {
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight")
        let other = LauncherHotkeyWait(combo: KeyCombo(.space, .control), owner: "Select the previous input source")
        let texts =
            SpotlightShortcutGuide.steps + [
                SpotlightShortcutGuide.waitingNote(wait), SpotlightShortcutGuide.waitingNote(other),
                SpotlightShortcutGuide.waitingLine(wait), SpotlightShortcutGuide.menuTitle(wait),
            ]
        for text in texts {
            #expect(!text.contains(KeyCombo(.space, .option).displayString))
            #expect(!text.contains("Option"))
        }
    }

    @Test func listsFeaturesThatAreOffByDefaultAndSwitchesThemOn() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        model.next()
        model.next()
        #expect(model.step == .features)
        #expect(
            model.optionalFeatures == [
                OnboardingModel.OptionalFeature(
                    id: "helper", name: "Window Helper", summary: "Names windows.", icon: .symbol("macwindow"),
                    isEnabled: false)
            ])
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring])

        await model.setEnabled(true, feature: "helper")
        #expect(model.optionalFeatures.map(\.isEnabled) == [true])
        #expect(bed.preferences.isEnabled(feature: "helper"))
        #expect(bed.directory.feature("helper")?.isEnabled == true)
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(bed.fakes.permissions.requests.isEmpty)
        model.next()
        #expect(model.step == .permissions)
        model.back()
        #expect(model.step == .features)

        await model.setEnabled(false, feature: "helper")
        #expect(model.optionalFeatures.map(\.isEnabled) == [false])
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring])
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
