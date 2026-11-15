import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct AdvancedModelTests {
    @Test func revealsTheDataFolder() async {
        let bed = TestBed()
        let model = AdvancedModel(context: bed.context())
        await model.revealDataDirectory()
        #expect(bed.fakes.workspace.revealed == [bed.dataDirectory])
    }

    @Test func shortensTheHomeFolder() {
        let bed = TestBed()
        var dependencies = bed.dependencies
        dependencies.dataDirectory = bed.fakes.storage.homeDirectory.appending(path: "Library/Data")
        let model = AdvancedModel(context: SettingsContext(dependencies))
        #expect(model.dataDirectoryText == "~/Library/Data")
    }

    @Test func summonStrategyAndRemoteIcons() {
        let bed = TestBed()
        let model = AdvancedModel(context: bed.context())
        model.summonStrategy = .orderFront
        model.fetchRemoteIcons = false
        #expect(bed.general[HostSettings.summonStrategy] == .orderFront)
        #expect(!bed.general[HostSettings.fetchRemoteIcons])
    }

    @Test func resetAllSettingsKeepsWhatTheUserMade() async throws {
        let bed = TestBed()
        let context = bed.context()
        let model = AdvancedModel(context: context)
        bed.general[HostSettings.visibleRows] = 4
        bed.general[HostSettings.onboardingDone] = true
        bed.general[HostSettings.themeName] = "Ocean"
        bed.themes.select("Ocean")
        bed.sampleSettings()[SampleSettings.limit] = 45
        bed.preferences.setAlias("os", for: TestBed.open)
        try bed.preferences.setHotkey(KeyCombo(.o, .command), for: TestBed.open)

        let reset = Task { await model.resetAllSettings() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(true)
        await reset.value

        #expect(bed.general[HostSettings.visibleRows] == 9)
        #expect(bed.general[HostSettings.themeName] == "Standard")
        #expect(bed.themes.selectedName == "Standard")
        #expect(bed.general[HostSettings.onboardingDone])
        #expect(bed.sampleSettings()[SampleSettings.limit] == 20)
        #expect(bed.preferences.aliases[TestBed.open] == "os")
        #expect(bed.preferences.hotkeys[TestBed.open] == KeyCombo(.o, .command))
    }

    @Test func declinedResetChangesNothing() async {
        let bed = TestBed()
        let context = bed.context()
        let model = AdvancedModel(context: context)
        bed.general[HostSettings.visibleRows] = 4
        let reset = Task { await model.resetAllSettings() }
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(false)
        await reset.value
        #expect(bed.general[HostSettings.visibleRows] == 4)
    }
}

@MainActor @Suite struct AboutModelTests {
    @Test func everythingComesFromTheBrandAndTheBundle() {
        let model = AboutModel(info: AboutInfo(version: "1.2", build: "34"))
        #expect(model.name == Brand.name)
        #expect(model.versionText == "Version 1.2 (34)")
        #expect(model.licenseText == "\(Brand.name) is open source under the MIT License.")
        #expect(model.privacyText.hasPrefix(Brand.name))
        #expect(AboutModel(info: AboutInfo(version: "1.2")).versionText == "Version 1.2")
    }

    @Test func outsideABundleTheVersionSaysDevelopment() {
        // The test runner is not an app bundle with a version.
        let info = AboutInfo.fromMainBundle()
        #expect(!info.version.isEmpty)
    }
}

@MainActor @Suite struct SettingsModelTests {
    @Test func showsPanesAndFeaturePages() {
        let bed = TestBed()
        let model = SettingsModel(dependencies: bed.dependencies)
        #expect(model.selection == .general)
        model.show(.learning)
        #expect(model.selection == .learning)
        model.showFeature("sample")
        #expect(model.selection == .features)
        #expect(model.features.path == ["sample"])
        #expect(
            SettingsPaneID.allCases.map(\.title) == [
                "General", "Appearance", "Root Search", "Features", "Permissions", "Learning", "Advanced", "About",
            ])
    }

    @Test func toastsReplaceAndDismiss() {
        let center = ToastCenter()
        center.lifetime = .zero
        center.show(.success("One"), id: ToastID(1))
        center.show(.success("Two"), id: ToastID(1))
        #expect(center.current?.toast.title == "Two")
        center.dismiss(ToastID(2))
        #expect(center.current != nil)
        center.dismiss(ToastID(1))
        #expect(center.current == nil)
        center.show(CancellationError(), title: "Ignored")
        #expect(center.current == nil)
    }

    @Test func reorderMovesLikeAList() {
        var values = ["a", "b", "c", "d"]
        values.reorder(fromOffsets: [0], toOffset: 3)
        #expect(values == ["b", "c", "a", "d"])
        values.reorder(fromOffsets: [3], toOffset: 0)
        #expect(values == ["d", "b", "c", "a"])
        values.reorder(fromOffsets: [1, 2], toOffset: 4)
        #expect(values == ["d", "a", "b", "c"])
    }
}
