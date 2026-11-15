import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct FeaturesModelTests {
    @Test func listsEveryFeatureWithItsSwitch() async {
        let bed = TestBed()
        let model = FeaturesModel(context: bed.context())
        #expect(model.features.map(\.id) == ["sample", "helper"])
        #expect(model.features.map(\.isEnabled) == [true, false])
        #expect(model.features[0].status?.level == .warning)
        #expect(model.features[0].commandCount == 3)
        await model.setEnabled(true, feature: "helper")
        #expect(model.isEnabled("helper"))
        #expect(bed.directory.feature("helper")?.isEnabled == true)
        model.open("sample")
        #expect(model.path == ["sample"])
        #expect(model.page("sample") === model.page("sample"))
    }

    @Test func statusOffersGrantsForMissingPermissionsOnly() async {
        let bed = TestBed(permissions: .notDetermined)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        #expect(page.status?.title == "Keyword expansion is paused")
        #expect(page.missingStatusPermissions.map(\.permission) == [.inputMonitoring])
        #expect(page.missingStatusPermissions.first?.reason == "Expand sample keywords as you type.")
        #expect(bed.fakes.permissions.requests.isEmpty)
        await page.grant(.inputMonitoring)
        #expect(bed.fakes.permissions.requests == [.inputMonitoring])
        #expect(page.missingStatusPermissions.isEmpty)
    }

    @Test func aDeniedPermissionOpensSystemSettingsInstead() async {
        let bed = TestBed(permissions: .denied)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        await page.grant(.inputMonitoring)
        #expect(bed.fakes.permissions.requests.isEmpty)
        #expect(bed.fakes.permissions.openedSettings == [.inputMonitoring])
    }

    @Test func statusFollowsDeclarationChanges() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        bed.sample.status = nil
        bed.directory.reload("sample")
        #expect(page.status == nil)
    }

    @Test func commandsCarryAliasHotkeyAndSwitch() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        #expect(page.commands.map(\.title) == ["Open Sample", "List Samples", "Clear Samples"])
        let open = page.commands[0]
        open.aliasDraft = "  OS "
        open.commitAlias()
        #expect(bed.preferences.aliases[TestBed.open] == "os")
        #expect(open.alias == "os")
        open.aliasDraft = ""
        open.commitAlias()
        #expect(bed.preferences.aliases[TestBed.open] == nil)

        open.isEnabled = false
        #expect(!bed.preferences.isEnabled(command: TestBed.open))
        #expect(bed.directory.command(TestBed.open)?.isEnabled == false)

        open.hotkey.beginRecording()
        open.hotkey.handle(key: .o, modifiers: [.command, .shift])
        #expect(bed.preferences.hotkeys[TestBed.open] == KeyCombo(.o, [.command, .shift]))
        // The same model is kept across reads, so a review in progress survives a redraw.
        #expect(page.commands[0] === open)
    }

    @Test func presetIsReviewedThenApplied() throws {
        let bed = TestBed()
        let context = bed.context()
        let page = FeatureDetailModel(featureID: "sample", context: context)
        let taken = KeyCombo(.o, [.control, .option])
        try bed.preferences.setHotkey(taken, for: TestBed.show)
        #expect(page.presets.map(\.name) == ["Classic"])
        page.review(page.presets[0])
        let review = try #require(page.presetReview)
        #expect(review.bindings.map(\.title) == ["Open Sample", "List Samples"])
        #expect(review.bindings[0].conflictText == "Show Windows")
        #expect(!review.bindings[0].isBlocked)
        #expect(review.bindings[1].conflicts.isEmpty)
        #expect(!review.isClean)
        // Nothing is bound before the user applies.
        #expect(bed.preferences.hotkeys[TestBed.open] == nil)
        page.applyReviewedPreset()
        #expect(page.presetReview == nil)
        #expect(bed.preferences.hotkeys[TestBed.open] == taken)
        #expect(bed.preferences.hotkeys[TestBed.list] == KeyCombo(.l, [.control, .option]))
        #expect(bed.preferences.hotkeys[TestBed.show] == nil)
        #expect(context.toasts.current?.toast.title == "Applied Classic")
    }

    @Test func presetSkipsHotkeysThatCannotBeTaken() throws {
        let bed = TestBed()
        let context = bed.context()
        bed.preferences.launcherHotkey = KeyCombo(.l, [.control, .option])
        let page = FeatureDetailModel(featureID: "sample", context: context)
        page.review(page.presets[0])
        #expect(page.presetReview?.bindings[1].isBlocked == true)
        page.applyReviewedPreset()
        #expect(bed.preferences.hotkeys[TestBed.open] == KeyCombo(.o, [.control, .option]))
        #expect(bed.preferences.hotkeys[TestBed.list] == nil)
        #expect(context.toasts.current?.toast.style == .failure)
        #expect(context.toasts.current?.toast.message == "Not bound: List Samples.")
    }

    @Test func cancellingAPresetChangesNothing() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        page.review(page.presets[0])
        page.cancelPresetReview()
        #expect(bed.preferences.hotkeys.isEmpty)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FeaturePaneTests {
    private func items(_ page: FeatureDetailModel) -> [String: PaneItemModel] {
        Dictionary(uniqueKeysWithValues: page.sections.flatMap(\.items).map { ($0.title, $0) })
    }

    @Test func drawsEverySectionAndItem() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        #expect(page.sections.map(\.title) == ["Behavior", "Lists", "Maintenance"])
        #expect(page.sections[0].footer == "Samples are synthetic.")
        #expect(page.sections.flatMap(\.items).count == 16)
        // Reads return the same models, so typed state survives.
        #expect(page.sections[0].items[0] === page.sections[0].items[0])
    }

    @Test func togglePickerTextAndStepperWriteTheFeaturesSettings() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let items = items(page)
        let settings = bed.sampleSettings()

        let toggle = items["Paste after choosing"]!
        #expect(toggle.bool)
        toggle.bool = false
        #expect(!settings[SampleSettings.autoPaste])

        let picker = items["Layout"]!
        #expect(picker.pickerIndex == 0)
        picker.pickerIndex = 1
        #expect(settings[SampleSettings.layout] == "grid")

        let text = items["Prefix"]!
        text.text = "x-"
        #expect(settings[SampleSettings.prefix] == "x-")

        let stepper = items["Keep"]!
        #expect(stepper.int == 20)
        stepper.int = 500
        #expect(settings[SampleSettings.limit] == 50)
    }

    @Test func seesSettingsTheFeatureChanged() async {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let toggle = items(page)["Paste after choosing"]!
        bed.sampleSettings()[SampleSettings.autoPaste] = false
        await bed.fakes.settle()
        #expect(!toggle.bool)
    }

    @Test func secretsGoToTheKeychainNotSettings() async {
        let bed = TestBed()
        let context = bed.context()
        let page = FeatureDetailModel(featureID: "sample", context: context)
        let secret = items(page)["Service token"]!
        await page.appeared()
        #expect(!secret.hasSecret)
        secret.secretDraft = " abc123 "
        await secret.saveSecret()
        #expect(bed.fakes.secrets.values["sample.token"] == "abc123")
        #expect(secret.secretDraft.isEmpty)
        #expect(secret.hasSecret)
        #expect(!bed.fakes.settings.values.keys.contains { $0.contains("token") })
        await secret.removeSecret()
        #expect(bed.fakes.secrets.values["sample.token"] == nil)
        #expect(!secret.hasSecret)
    }

    @Test func hotkeySettingIsStoredWithConflictReview() throws {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let recorder = try #require(items(page)["Pick hotkey"]?.hotkey)
        let combo = KeyCombo(.p, [.command, .control])
        try bed.preferences.setHotkey(combo, for: TestBed.list)
        recorder.beginRecording()
        recorder.handle(key: .p, modifiers: [.command, .control])
        guard case .review = recorder.state else {
            Issue.record("no review")
            return
        }
        recorder.confirmReplace()
        #expect(bed.sampleSettings()[SampleSettings.pickHotkey] == combo)
        #expect(bed.preferences.hotkeys[TestBed.list] == nil)
        recorder.clear()
        #expect(bed.sampleSettings()[SampleSettings.pickHotkey] == nil)
    }

    @Test func buttonsRunFromSettingsWithToastsInTheWindow() async {
        let bed = TestBed()
        let context = bed.context()
        let page = FeatureDetailModel(featureID: "sample", context: context)
        await items(page)["Rebuild Index"]!.run()
        #expect(bed.sample.buttonLaunches == [.settings])
        #expect(context.toasts.current?.toast.title == "Rebuilt")
        #expect(context.toasts.current?.toast.style == .success)
    }

    @Test func aThrowingButtonShowsAFailureToast() async {
        let bed = TestBed()
        let context = bed.context()
        let page = FeatureDetailModel(featureID: "sample", context: context)
        await items(page)["Break Things"]!.run()
        #expect(context.toasts.current?.toast.style == .failure)
        #expect(context.toasts.current?.toast.title == "Nothing to break")
        #expect(context.toasts.current?.toast.message == "Samples are fine.")
    }

    @Test func aButtonWithAConfirmationAsksFirst() async {
        let bed = TestBed()
        let context = bed.context()
        let page = FeatureDetailModel(featureID: "sample", context: context)
        let erase = items(page)["Erase Samples"]!
        #expect(erase.buttonStyle == .destructive)

        let declined = Task { await erase.run() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(false)
        await declined.value
        #expect(bed.sample.buttonLaunches.isEmpty)

        let accepted = Task { await erase.run() }
        #expect(await eventually { context.confirmations.pending != nil })
        #expect(context.confirmations.pending?.confirmation.title == "Erase every sample?")
        context.confirmations.answer(true)
        await accepted.value
        #expect(bed.sample.buttonLaunches == [.settings])
    }

    @Test func textListAddsAndRemoves() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let list = items(page)["Ignored words"]!
        list.listDraft = " alpha "
        list.addDraft()
        list.listDraft = "beta"
        list.addDraft()
        list.listDraft = "alpha"
        list.addDraft()
        #expect(bed.sampleSettings()[SampleSettings.ignored] == ["alpha", "beta"])
        #expect(list.listDraft.isEmpty)
        list.removeEntries(at: [0])
        #expect(bed.sampleSettings()[SampleSettings.ignored] == ["beta"])
    }

    @Test func applicationAndFolderListsUseTheOpenDialog() async {
        let bed = TestBed()
        bed.fakes.workspace.installed = [AppInfo(bundleID: "com.example.editor", name: "Example Editor")]
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let apps = items(page)["Skip in apps"]!
        bed.fakes.fileDialogs.filesToChoose = [URL(fileURLWithPath: "/Applications/Editor.app")]
        await apps.addFromPicker()
        #expect(bed.sampleSettings()[SampleSettings.skipApps] == ["com.example.editor"])
        #expect(apps.label(forEntry: "com.example.editor") == "Example Editor")
        #expect(bed.fakes.fileDialogs.openRequests.last?.allowedTypes == ["app"])

        let folders = items(page)["Folders"]!
        let home = bed.fakes.storage.homeDirectory
        bed.fakes.fileDialogs.filesToChoose = [home.appending(path: "Projects")]
        await folders.addFromPicker()
        #expect(bed.fakes.fileDialogs.openRequests.last?.canChooseDirectories == true)
        #expect(folders.label(forEntry: folders.strings[0]) == "~/Projects")
    }

    @Test func multiSelectLoadsOptionsWhenThePageAppears() async {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let groups = items(page)["Groups"]!
        #expect(groups.choices.isEmpty)
        #expect(bed.sample.optionLoads == 0)
        await page.appeared()
        #expect(bed.sample.optionLoads == 1)
        #expect(groups.choices.map(\.id) == ["work", "home"])
        groups.setChosen(true, "home")
        groups.setChosen(true, "work")
        groups.setChosen(false, "home")
        #expect(bed.sampleSettings()[SampleSettings.groups] == ["work"])
        #expect(groups.isChosen("work"))
        await page.appeared()
        #expect(bed.sample.optionLoads == 2)
    }

    @Test func applicationPicker() async {
        let bed = TestBed()
        bed.fakes.workspace.installed = [AppInfo(bundleID: "com.example.writer", name: "Example Writer")]
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let editor = items(page)["Editor"]!
        #expect(editor.applicationTitle == nil)
        bed.fakes.fileDialogs.filesToChoose = [URL(fileURLWithPath: "/Applications/Writer.app")]
        await editor.chooseApplication()
        #expect(bed.sampleSettings()[SampleSettings.editor] == "com.example.writer")
        #expect(editor.applicationTitle == "Example Writer")
        editor.clearApplication()
        #expect(editor.applicationTitle == nil)
    }

    @Test func permissionItemShowsLiveStatusAndGrantsOnlyWhenPressed() async {
        let bed = TestBed(permissions: .notDetermined)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let permission = items(page)["Accessibility"]!
        #expect(permission.permissionStatus == .notDetermined)
        #expect(permission.permissionReason == "Paste the chosen sample into the frontmost app.")
        await page.appeared()
        #expect(bed.fakes.permissions.requests.isEmpty)
        bed.fakes.permissions.set(.accessibility, to: .granted)
        #expect(permission.permissionStatus == .granted)
        bed.fakes.permissions.set(.accessibility, to: .notDetermined)
        await permission.grant()
        #expect(bed.fakes.permissions.requests == [.accessibility])
        await permission.openPermissionSettings()
        #expect(bed.fakes.permissions.openedSettings == [.accessibility])
    }

    @Test func noteIsText() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        let note = page.sections[2].items.last!
        guard case .note = note.control else {
            Issue.record("not a note")
            return
        }
        #expect(note.title == "Samples never leave the test.")
    }
}
