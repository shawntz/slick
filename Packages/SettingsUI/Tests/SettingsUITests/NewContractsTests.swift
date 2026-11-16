import AppKit
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

/// The settings window on the contracts Kit added for the eight new features: a picker that asks
/// before a choice that deletes data, and grants announced to the features.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NewContractsTests {
    @Test func aPickerChoiceThatDeletesDataAsksFirstAndStoresOnlyOnYes() async throws {
        let bed = TestBed()
        bed.directory.register(HistoryPickerFeature.self, fakes: bed.fakes)
        let context = bed.context()
        // An item holds its page unowned, as the window does; keep the page for the whole test.
        let page = FeatureDetailModel(featureID: "history-picker", context: context)
        defer { withExtendedLifetime(page) {} }
        let item = try #require(page.sections.flatMap(\.items).first { $0.title == "Keep at most" })
        let settings = FeatureSettings(featureID: "history-picker", service: bed.fakes.settings)
        #expect(item.pickerIndex == 0)

        // A smaller history asks. Until the answer the picker shows what is stored.
        item.pickerIndex = 1
        #expect(await eventually { context.confirmations.pending != nil })
        #expect(context.confirmations.pending?.confirmation.title == "Keep Only 10 Items?")
        #expect(context.confirmations.pending?.confirmation.isDestructive == true)
        #expect(item.pendingChoice != nil)
        #expect(settings[HistoryPickerFeature.keep] == 100)
        #expect(item.pickerIndex == 0)

        // No keeps it.
        context.confirmations.answer(false)
        #expect(await eventually { item.pendingChoice == nil })
        #expect(settings[HistoryPickerFeature.keep] == 100)
        #expect(item.pickerIndex == 0)

        // Yes stores it.
        item.pickerIndex = 1
        #expect(await eventually { context.confirmations.pending != nil })
        context.confirmations.answer(true)
        #expect(await eventually { settings[HistoryPickerFeature.keep] == 10 })
        #expect(item.pickerIndex == 1)

        // A larger history loses nothing, so it is stored at once.
        item.pickerIndex = 0
        #expect(context.confirmations.pending == nil)
        #expect(settings[HistoryPickerFeature.keep] == 100)
    }

    @Test func aPickerThatNeverAsksStoresAtOnce() {
        let bed = TestBed()
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        defer { withExtendedLifetime(page) {} }
        let picker = page.sections.flatMap(\.items).first { $0.title == "Layout" }
        picker?.pickerIndex = 1
        #expect(bed.sampleSettings()[SampleSettings.layout] == "grid")
        #expect(picker?.pendingChoice == nil)
    }

    @Test func aGrantFromThePermissionsPaneReachesTheFeaturesOnce() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        await model.grant(.accessibility)
        #expect(bed.directory.announcedGrants == [.accessibility])
        await model.grant(.accessibility)
        #expect(bed.directory.announcedGrants == [.accessibility])
    }

    @Test func aGrantFromAFeaturePaneItemReachesTheFeatures() async throws {
        let bed = TestBed(permissions: .notDetermined)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        defer { withExtendedLifetime(page) {} }
        let item = try #require(page.sections.flatMap(\.items).first { $0.permission == .accessibility })
        await item.grant()
        #expect(bed.directory.announcedGrants == [.accessibility])
    }

    @Test func aGrantFromAFeaturesStatusBannerReachesTheFeatures() async {
        let bed = TestBed(permissions: .notDetermined)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        await page.grant(.inputMonitoring)
        #expect(bed.directory.announcedGrants == [.inputMonitoring])
    }

    @Test func aGrantMadeInSystemSettingsWhileAPaneWatchesReachesTheFeatures() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = PermissionsModel(context: bed.context())
        await model.openSettings(for: .fullDiskAccess)
        #expect(bed.fakes.permissions.openedSettings == [.fullDiskAccess])
        // The user turns it on in System Settings; the pane's stream sees it.
        bed.fakes.permissions.set(.fullDiskAccess, to: .granted)
        await model.statusChanged(.fullDiskAccess)
        #expect(bed.directory.announcedGrants == [.fullDiskAccess])
        // A second change notice for the same grant announces nothing.
        await model.statusChanged(.fullDiskAccess)
        #expect(bed.directory.announcedGrants == [.fullDiskAccess])
    }

    @Test func aPermissionGrantedAllAlongIsNeverAnnounced() async {
        let bed = TestBed(permissions: .granted)
        let model = PermissionsModel(context: bed.context())
        await model.grant(.accessibility)
        await model.statusChanged(.accessibility)
        #expect(bed.directory.announcedGrants.isEmpty)
    }

    @Test func aPaneItemThatOpenedSystemSettingsAnnouncesTheGrantWhenItShowsAgain() async throws {
        let bed = TestBed(permissions: .notDetermined)
        let page = FeatureDetailModel(featureID: "sample", context: bed.context())
        defer { withExtendedLifetime(page) {} }
        let item = try #require(page.sections.flatMap(\.items).first { $0.permission == .accessibility })
        await item.openPermissionSettings()
        bed.fakes.permissions.set(.accessibility, to: .granted)
        await item.appeared()
        #expect(bed.directory.announcedGrants == [.accessibility])
    }
}

/// The window a scenario captures keeps the place it is given, even off every screen. Checked
/// without ordering any window in.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PlacedWindowTests {
    @Test func keepsAFrameOffEveryScreen() {
        let window = PlacedWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        let offscreen = CGRect(x: -20000, y: -20000, width: 200, height: 120)
        #expect(window.constrainFrameRect(offscreen, to: nil) == offscreen)
        #expect(!window.isVisible)
    }
}
