import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct GeneralModelTests {
    @Test func readsAndWritesGeneralSettings() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        #expect(model.panelScreen == .pointer)
        #expect(model.panelSizing == .fixed)
        #expect(model.visibleRows == 9)
        #expect(model.resetToRootAfter == 90)
        #expect(model.showStatusItem)

        model.panelScreen = .activeWindow
        model.panelSizing = .fitContent
        model.visibleRows = 12
        model.resetToRootAfter = 0
        model.showStatusItem = false
        #expect(bed.general[HostSettings.panelScreen] == .activeWindow)
        #expect(bed.general[HostSettings.panelSizing] == .fitContent)
        #expect(bed.general[HostSettings.visibleRows] == 12)
        #expect(bed.general[HostSettings.resetToRootAfter] == 0)
        #expect(!bed.general[HostSettings.showStatusItem])
    }

    @Test func keepsVisibleRowsInRange() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        model.visibleRows = 100
        #expect(model.visibleRows == GeneralModel.visibleRowRange.upperBound)
        model.visibleRows = 0
        #expect(model.visibleRows == GeneralModel.visibleRowRange.lowerBound)
    }

    @Test func resetChoicesIncludeAStoredValueThatIsNotListed() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        #expect(model.resetChoices.map(\.seconds) == GeneralModel.resetChoices.map(\.seconds))
        bed.general[HostSettings.resetToRootAfter] = 45
        #expect(model.resetChoices.last?.seconds == 45)
        model.resetToRootAfter = -30
        #expect(bed.general[HostSettings.resetToRootAfter] == -1)
    }

    @Test func seesChangesMadeElsewhere() async {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        bed.general[HostSettings.visibleRows] = 6
        await bed.fakes.settle()
        #expect(model.visibleRows == 6)
    }

    @Test func launchAtLoginGoesThroughTheLoginItem() {
        let bed = TestBed()
        let context = bed.context()
        let model = GeneralModel(context: context)
        #expect(!model.launchAtLogin)
        model.launchAtLogin = true
        #expect(bed.loginItem.requests == [true])
        #expect(model.launchAtLogin)
        #expect(context.toasts.current == nil)
    }

    @Test func aRefusedLoginItemShowsAToastAndTheRealState() {
        let bed = TestBed()
        let context = bed.context()
        bed.loginItem.failure = ActionFailure("The system said no")
        let model = GeneralModel(context: context)
        model.launchAtLogin = true
        #expect(!model.launchAtLogin)
        #expect(context.toasts.current?.toast.title == "The system said no")
        #expect(context.toasts.current?.toast.style == .failure)
    }

    @Test func warnsWhenNothingOpensTheLauncher() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        #expect(!model.isUnreachable)
        model.launcherHotkey.clear()
        #expect(bed.general[HostSettings.launcherHotkey] == nil)
        #expect(!model.isUnreachable)
        model.showStatusItem = false
        #expect(model.isUnreachable)
    }

    @Test func recordsTheLauncherHotkey() {
        let bed = TestBed()
        let model = GeneralModel(context: bed.context())
        model.launcherHotkey.beginRecording()
        model.launcherHotkey.handle(key: .k, modifiers: [.command, .option])
        #expect(bed.general[HostSettings.launcherHotkey] == KeyCombo(.k, [.command, .option]))
        #expect(model.launcherHotkey.combo == KeyCombo(.k, [.command, .option]))
    }
}
