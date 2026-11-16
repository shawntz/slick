import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct OnboardingModelTests {
    @Test func walksEveryStepAndFinishes() async {
        let bed = TestBed(permissions: .notDetermined)
        var finished = 0
        let model = OnboardingModel(context: bed.context()) { finished += 1 }
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
        await model.next()
        #expect(model.step == .hotkey)
        await model.next()
        #expect(model.step == .features)
        await model.next()
        #expect(model.step == .permissions)
        model.back()
        #expect(model.step == .features)
        await model.next()
        await model.next()
        #expect(model.step == .theme)
        await model.next()
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
        await model.next()
        await model.next()
        #expect(model.step == .features)
        await model.next()
        #expect(model.step == .theme)
        model.back()
        #expect(model.step == .features)
    }

    @Test func skipsTheFeaturesStepWhenEveryFeatureIsOnByDefault() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.entries.removeAll { $0.id == "helper" }
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.optionalFeatures.isEmpty)
        await model.next()
        await model.next()
        #expect(model.step == .permissions)
        model.back()
        #expect(model.step == .hotkey)
    }

    @Test func listsOnlyEnabledFeaturesPermissionsAndNeverAsksUnasked() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        await model.next()
        await model.next()
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
        await model.next()
        await model.next()
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

    @Test func anotherShortcutGetsTheAdviceAndTheStepTurnsGreenWhenItEnds() async {
        let bed = TestBed()
        let combo = KeyCombo(.upArrow, .control)
        bed.general[HostSettings.launcherHotkey] = combo
        bed.hotkeyStatus.startWaiting(combo, owner: "Mission Control")
        let model = OnboardingModel(context: bed.context()) {}
        let wait = LauncherHotkeyWait(combo: combo, owner: "Mission Control")
        #expect(model.hotkeyGuide == .waiting(wait))
        #expect(!wait.isSpotlight)
        #expect(
            SpotlightShortcutGuide.cannotTurnOffNote(wait)
                == "Mission Control uses ⌃↑ right now. To open \(Brand.name) with ⌃↑, turn off that shortcut in "
                + "System Settings, under Keyboard. You can also click the field above and press other keys.")
        #expect(SpotlightShortcutGuide.waitingLine(wait) == "\(Brand.name) waits until ⌃↑ is free.")

        model.openKeyboardSettings()
        #expect(await eventually { bed.fakes.workspace.opened == [SpotlightShortcutGuide.keyboardSettingsURL] })

        // Continue never touches a shortcut the app cannot turn off; it moves on.
        await model.next()
        #expect(model.step == .hotkey)
        model.show(.hotkey)
        await model.next()
        #expect(bed.hotkeyStatus.turnOffs == 0)
        #expect(model.step == .features)

        model.back()
        bed.hotkeyStatus.bindWaited()
        #expect(await eventually { model.hotkeyGuide == .freed(combo) })
        #expect(SpotlightShortcutGuide.freedLine(combo) == "⌃↑ opens \(Brand.name) now.")
    }

    @Test func continueTurnsSpotlightOffBindsTheHotkeyAndTheLineTurnsGreen() async {
        let bed = TestBed()
        bed.hotkeyStatus.startWaiting(canTurnOff: true)
        let model = OnboardingModel(context: bed.context()) {}
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight", canTurnOff: true)
        #expect(model.hotkeyGuide == .waiting(wait))
        #expect(
            SpotlightShortcutGuide.takeOverNote(wait)
                == "⌘Space opens Spotlight right now. When you press Continue, \(Brand.name) turns off Spotlight's "
                + "shortcut. Then ⌘Space opens \(Brand.name).")
        #expect(
            SpotlightShortcutGuide.takeOverFootnote(wait)
                == "To keep ⌘Space for Spotlight, click the field above and press other keys. To turn Spotlight's "
                + "shortcut back on later, open System Settings, Keyboard, Keyboard Shortcuts, Spotlight.")
        // Nothing is turned off before the person continues.
        #expect(bed.hotkeyStatus.turnOffs == 0)
        await model.next()
        #expect(model.step == .hotkey)
        // Continue turns the shortcut off, binds the hotkey and moves on in one press.
        await model.next()
        #expect(model.step == .features)
        #expect(bed.hotkeyStatus.turnOffs == 1)
        #expect(bed.hotkeyStatus.bound == KeyCombo(.space, .command))
        #expect(!model.isTakingKeys)
        // Back on the step, the green line says the keys are Slick's, and Continue asks nothing more.
        model.back()
        #expect(model.step == .hotkey)
        #expect(await eventually { model.hotkeyGuide == .freed(KeyCombo(.space, .command)) })
        await model.next()
        #expect(model.step == .features)
        #expect(bed.hotkeyStatus.turnOffs == 1)
        model.show(.done)
        #expect(SpotlightShortcutGuide.doneBound(KeyCombo(.space, .command)) == "Press ⌘Space to open \(Brand.name).")
    }

    @Test func aFailedTryStaysOnTheStepWithItsSentence() async {
        let bed = TestBed()
        bed.hotkeyStatus.startWaiting(canTurnOff: true)
        bed.hotkeyStatus.turnOffWorks = false
        let model = OnboardingModel(context: bed.context()) {}
        model.show(.hotkey)
        await model.next()
        #expect(model.step == .hotkey)
        #expect(bed.hotkeyStatus.turnOffs == 1)
        let failed = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight", turnOffFailed: true)
        #expect(await eventually { model.hotkeyGuide == .waiting(failed) })
        #expect(
            SpotlightShortcutGuide.failedNote(failed)
                == "\(Brand.name) could not turn off Spotlight's shortcut. Turn off Show Spotlight search in System "
                + "Settings, under Keyboard, Keyboard Shortcuts, Spotlight.")
        // The person can move on; the app does not try again.
        await model.next()
        #expect(model.step == .features)
        #expect(bed.hotkeyStatus.turnOffs == 1)
        model.show(.done)
        #expect(
            SpotlightShortcutGuide.doneWaiting(failed)
                == "⌘Space still opens Spotlight. Click the bolt in the menu bar to open \(Brand.name) for now.")
    }

    @Test func theDoneStepWithNoHotkey() {
        #expect(
            SpotlightShortcutGuide.doneNoHotkey
                == "Click the bolt in the menu bar to open \(Brand.name). You can set a hotkey in Settings.")
    }

    @Test func theGuideNeverSuggestsOptionSpace() {
        let wait = LauncherHotkeyWait(combo: KeyCombo(.space, .command), owner: "Spotlight", canTurnOff: true)
        let other = LauncherHotkeyWait(combo: KeyCombo(.space, .control), owner: "Select the previous input source")
        let texts = [
            SpotlightShortcutGuide.takeOverNote(wait), SpotlightShortcutGuide.takeOverFootnote(wait),
            SpotlightShortcutGuide.failedNote(wait), SpotlightShortcutGuide.cannotTurnOffNote(other),
            SpotlightShortcutGuide.waitingLine(wait), SpotlightShortcutGuide.menuTitle(wait),
            SpotlightShortcutGuide.paneNote(wait),
        ]
        for text in texts {
            #expect(!text.contains(KeyCombo(.space, .option).displayString))
            #expect(!text.contains("Option"))
        }
    }

    @Test func listsFeaturesThatAreOffByDefaultAndSwitchesThemOnWhenTheUserContinues() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        await model.next()
        await model.next()
        #expect(model.step == .features)
        #expect(
            model.optionalFeatures == [
                OnboardingModel.OptionalFeature(
                    id: "helper", name: "Window Helper", summary: "Names windows.", icon: .symbol("macwindow"),
                    isEnabled: false)
            ])
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring])

        // The switch moves at once; the feature turns on only when the user continues.
        model.setEnabled(true, feature: "helper")
        #expect(model.optionalFeatures.map(\.isEnabled) == [true])
        #expect(!bed.preferences.isEnabled(feature: "helper"))
        await model.next()
        #expect(model.step == .permissions)
        #expect(bed.preferences.isEnabled(feature: "helper"))
        #expect(bed.directory.feature("helper")?.isEnabled == true)
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(bed.fakes.permissions.requests.isEmpty)

        model.back()
        #expect(model.step == .features)
        model.setEnabled(false, feature: "helper")
        #expect(bed.preferences.isEnabled(feature: "helper"))
        await model.next()
        #expect(!bed.preferences.isEnabled(feature: "helper"))
        #expect(model.permissionItems.map(\.permission) == [.accessibility, .inputMonitoring])
    }

    @Test func aSuggestedFeatureStartsOnAndTurnsOnWhenTheUserContinues() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(SuggestedFeature.self, fakes: bed.fakes)
        let model = OnboardingModel(context: bed.context()) {}
        await model.next()
        await model.next()
        #expect(model.step == .features)
        #expect(model.optionalFeatures.map(\.id) == ["helper", "suggested"])
        #expect(model.optionalFeatures.map(\.isEnabled) == [false, true])
        #expect(!bed.preferences.isEnabled(feature: "suggested"))
        await model.next()
        #expect(bed.preferences.isEnabled(feature: "suggested"))
        #expect(!bed.preferences.isEnabled(feature: "helper"))
    }

    /// Scenarios play the step through the same model: a suggested feature switched off stays off,
    /// another switched on turns on, and onboarding is not marked done.
    @Test func aRehearsalOfTheFeaturesStepAppliesTheSwitchesAsTheWindowWould() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(SuggestedFeature.self, fakes: bed.fakes)
        let problems = await OnboardingRehearsal.chooseOptionalFeatures(
            ["suggested": false, "helper": true, "nothing": true], dependencies: bed.dependencies)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("nothing") == true)
        #expect(!bed.preferences.isEnabled(feature: "suggested"))
        #expect(bed.preferences.isEnabled(feature: "helper"))
        #expect(OnboardingController.isNeeded(bed.fakes.settings))
    }

    @Test func closingBeforeContinuingAppliesNothingAndOnboardingOpensAgain() async {
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.register(SuggestedFeature.self, fakes: bed.fakes)
        let model = OnboardingModel(context: bed.context()) {}
        await model.next()
        await model.next()
        model.setEnabled(true, feature: "helper")
        // The window closes here: nothing calls next or finish.
        #expect(!bed.preferences.isEnabled(feature: "helper"))
        #expect(!bed.preferences.isEnabled(feature: "suggested"))
        #expect(OnboardingController.isNeeded(bed.fakes.settings))
    }

    @Test func anAllowedPermissionIsAnnouncedToTheFeaturesOnce() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        await model.allow(.inputMonitoring)
        #expect(bed.directory.announcedGrants == [.inputMonitoring])
        // Granted already: pressing again announces nothing new.
        await model.allow(.inputMonitoring)
        #expect(bed.directory.announcedGrants == [.inputMonitoring])
        // Refused: nothing is announced.
        bed.fakes.permissions.answer = .denied
        await model.allow(.accessibility)
        #expect(bed.directory.announcedGrants == [.inputMonitoring])
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
