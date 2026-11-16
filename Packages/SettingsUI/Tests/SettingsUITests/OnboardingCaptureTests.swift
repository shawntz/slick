import AppKit
import Kit
import KitHosting
import KitHostingTesting
import Testing

@testable import SettingsUI

/// The onboarding window a scenario shows on one step for a picture: at the place given, off every
/// screen here, never key, applying nothing and marking nothing done.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct OnboardingCaptureTests {
    static let offscreen = CGPoint(x: -20000, y: -20000)

    @Test func goesStraightToAStepAndAppliesNothing() async {
        let bed = TestBed(permissions: .notDetermined)
        let model = OnboardingModel(context: bed.context()) {}
        #expect(model.show(.permissions))
        #expect(model.step == .permissions)
        #expect(model.show(.hotkey))
        #expect(model.step == .hotkey)
        // The helper's switch was never continued past, so it stays off.
        #expect(!bed.preferences.isEnabled(feature: "helper"))
        #expect(!bed.general[HostSettings.onboardingDone])

        // A step with nothing to show is refused, and the model stays where it was.
        bed.directory.entries.removeAll { $0.id == "helper" }
        #expect(!model.hasContent(.features))
        #expect(!model.show(.features))
        #expect(model.step == .hotkey)
    }

    @Test func showsTheHotkeyStepAtThePlaceGivenWithoutKeyStatus() {
        _ = NSApplication.shared
        let bed = TestBed(permissions: .notDetermined)
        bed.hotkeyStatus.startWaiting()
        let controller = OnboardingController(dependencies: bed.dependencies)
        #expect(controller.shownStep == .welcome)
        #expect(controller.captureFrame == nil)

        let checksBefore = bed.hotkeyStatus.checks
        let frame = controller.showForCapture(.hotkey, at: Self.offscreen)
        #expect(bed.hotkeyStatus.checks == checksBefore + 1, "the hotkey checks whether Spotlight holds it")
        #expect(frame?.origin == Self.offscreen)
        #expect((frame?.width ?? 0) > 300)
        #expect(controller.captureFrame == frame)
        #expect(controller.shownStep == .hotkey)
        #expect(!NSApplication.shared.windows.contains { $0.isKeyWindow && $0.frame.origin == Self.offscreen })
        #expect(!bed.general[HostSettings.onboardingDone])

        // The same window moves to another step.
        let again = controller.showForCapture(.theme, at: Self.offscreen)
        #expect(again?.origin == Self.offscreen)
        #expect(controller.shownStep == .theme)

        controller.close()
        #expect(controller.captureFrame == nil)
        #expect(!bed.general[HostSettings.onboardingDone], "closing is finishing later")
    }

    @Test func refusesAStepWithNothingToShowAndOpensNoWindow() {
        _ = NSApplication.shared
        let bed = TestBed(permissions: .notDetermined)
        bed.directory.entries.removeAll { $0.id == "helper" }
        let controller = OnboardingController(dependencies: bed.dependencies)
        #expect(!controller.canShow(.features))
        #expect(controller.canShow(.hotkey))
        #expect(controller.showForCapture(.features, at: Self.offscreen) == nil)
        #expect(controller.captureFrame == nil)
        #expect(controller.shownStep == .welcome)
    }

    @Test func everyStepHasAName() {
        #expect(OnboardingStepID.allCases.map(\.rawValue) == OnboardingModel.Step.allCases.map { "\($0)" })
    }
}
