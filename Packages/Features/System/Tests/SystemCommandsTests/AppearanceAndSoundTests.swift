import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

@Suite("Toggle Dark Mode", .timeLimit(.minutes(1)))
@MainActor
struct AppearanceTests {
    @Test func switchesBackAndForth() async throws {
        let system = SystemHarness(isDark: false)
        try await system.harness.run("toggle-dark-mode")
        #expect(system.appearance.isDark)
        try await system.harness.run("toggle-dark-mode")
        #expect(!system.appearance.isDark)
        #expect(system.harness.huds == ["Switched to dark mode", "Switched to light mode"])
    }

    @Test func aMissingGrantForSystemEventsShowsThePermissionCard() async throws {
        let system = SystemHarness()
        let systemEvents = Permission.automation(bundleID: "com.apple.systemevents")
        system.appearance.fail(with: .permissionMissing(systemEvents))
        await #expect(throws: HarnessError.permissionRequired([systemEvents])) {
            try await system.harness.run("toggle-dark-mode")
        }
        #expect(!system.appearance.isDark)
    }

    @Test func runsAgainOnceTheUserGrantsIt() async throws {
        let system = SystemHarness()
        let systemEvents = Permission.automation(bundleID: "com.apple.systemevents")
        system.appearance.fail(with: .permissionMissing(systemEvents), once: true)
        // The card's Grant button asks the system; after a grant the command runs again and works.
        system.harness.grantsMissingPermissions = true
        try await system.harness.run("toggle-dark-mode")
        #expect(system.fakes.permissions.requests == [systemEvents])
        #expect(system.appearance.isDark)
        #expect(system.harness.huds == ["Switched to dark mode"])
    }

    @Test func saysSoWhenSystemEventsIsMissing() async throws {
        let system = SystemHarness()
        system.appearance.fail(with: .unavailable)
        try await system.runShowingErrors("toggle-dark-mode")
        #expect(system.harness.toasts.map(\.title) == ["System Events Is Not Available on This Mac"])
    }
}

@Suite("Sound", .timeLimit(.minutes(1)))
@MainActor
struct SoundTests {
    @Test func muteUnmuteAndToggle() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: false))
        try await system.harness.run("mute")
        #expect(system.sound.device?.isMuted == true)
        try await system.harness.run("unmute")
        #expect(system.sound.device?.isMuted == false)
        try await system.harness.run("toggle-mute")
        #expect(system.sound.device?.isMuted == true)
        try await system.harness.run("toggle-mute")
        #expect(system.sound.device?.isMuted == false)
        #expect(system.harness.huds == ["Sound Muted", "Sound Unmuted", "Sound Muted", "Sound Unmuted"])
    }

    @Test func volumeKeysMoveBySixteenthsByDefault() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: false))
        try await system.harness.run("volume-up")
        #expect(system.sound.device?.volume == 0.5625)
        try await system.harness.run("volume-down")
        try await system.harness.run("volume-down")
        #expect(system.sound.device?.volume == 0.4375)
        #expect(system.harness.huds == ["Volume 56%", "Volume 50%", "Volume 44%"])
    }

    @Test func theStepFollowsTheSetting() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.52, isMuted: false))
        system.settings[SystemSettings.volumeStep] = .tenPercent
        try await system.harness.run("volume-up")
        #expect(system.sound.device?.volume == 0.6)
        try await system.harness.run("volume-down")
        try await system.harness.run("volume-down")
        #expect(system.sound.device?.volume == 0.4)
    }

    @Test func raisingTheVolumeUnmutes() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.25, isMuted: true))
        try await system.harness.run("volume-up")
        #expect(system.sound.device == SoundState(volume: 0.3125, isMuted: false))
    }

    @Test func theVolumeStopsAtTheEnds() async throws {
        let system = SystemHarness(sound: SoundState(volume: 1, isMuted: false))
        try await system.harness.run("volume-up")
        #expect(system.sound.device?.volume == 1)
        let quiet = SystemHarness(sound: SoundState(volume: 0, isMuted: false))
        try await quiet.harness.run("volume-down")
        #expect(quiet.sound.device?.volume == 0)
        #expect(system.harness.huds == ["Volume 100%"])
        #expect(quiet.harness.huds == ["Volume 0%"])
    }

    @Test func fastPressesEachStartFromTheLastLevel() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: false))
        async let first = system.harness.run("volume-up")
        async let second = system.harness.run("volume-up")
        async let third = system.harness.run("volume-up")
        _ = try await (first, second, third)
        #expect(system.sound.device?.volume == 0.6875)
    }

    @Test(arguments: [("40", 0.4), ("40%", 0.4), (" 75 % ", 0.75), ("0", 0.0), ("100", 1.0), ("12.5", 0.125)])
    func setVolumeTakesANumberFromZeroToAHundred(text: String, level: Double) async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: false))
        try await system.harness.run("set-volume", arguments: ["level": text])
        #expect(system.sound.device?.volume == level)
        #expect(system.harness.huds == [HUD("Volume \(VolumeLevel.percent(level))%")])
    }

    @Test func settingTheVolumeToZeroLeavesTheMuteSwitchAlone() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: true))
        try await system.harness.run("set-volume", arguments: ["level": "0"])
        #expect(system.sound.device == SoundState(volume: 0, isMuted: true))
        try await system.harness.run("set-volume", arguments: ["level": "30"])
        #expect(system.sound.device == SoundState(volume: 0.3, isMuted: false))
    }

    @Test(arguments: ["loud", "150", "-5", "", "40%%", "4 0", "1e2", "."])
    func setVolumeExplainsWhatItAccepts(text: String) async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: false))
        if text.isEmpty {
            await #expect(throws: HarnessError.missingArgument("level")) {
                try await system.harness.run("set-volume", arguments: ["level": text])
            }
            return
        }
        try await system.runShowingErrors("set-volume", arguments: ["level": text])
        #expect(system.harness.toasts.map(\.title) == ["Enter a Volume from 0 to 100"])
        #expect(system.harness.toasts.first?.message == "For example, 40 or 40%.")
        #expect(system.sound.device?.volume == 0.5)
    }

    @Test func aDeviceWithoutAVolumeControlSaysSo() async throws {
        let system = SystemHarness(sound: SoundState(volume: nil, isMuted: false))
        try await system.runShowingErrors("volume-up")
        #expect(system.harness.toasts.map(\.title) == ["This Output Device Has No Volume Control"])
        try await system.runShowingErrors("set-volume", arguments: ["level": "20"])
        #expect(system.harness.toasts.count == 2)
    }

    @Test func aDeviceThatCannotBeMutedSaysSo() async throws {
        let system = SystemHarness(sound: SoundState(volume: 0.5, isMuted: nil))
        try await system.runShowingErrors("toggle-mute")
        #expect(system.harness.toasts.map(\.title) == ["This Output Device Cannot Be Muted"])
        try await system.harness.run("volume-up")
        #expect(system.sound.device?.volume == 0.5625, "the volume still works")
    }

    @Test func noOutputDeviceSaysSo() async throws {
        let system = SystemHarness(sound: nil)
        for id in ["mute", "volume-down"] {
            try await system.runShowingErrors(id)
        }
        #expect(system.harness.toasts.map(\.title) == Array(repeating: "No Sound Output to Change", count: 2))
    }
}

@Suite("Volume arithmetic", .timeLimit(.minutes(1)))
struct VolumeLevelTests {
    @Test(arguments: [
        ("40", 0.4), ("40%", 0.4), ("40 %", 0.4), ("  7 ", 0.07), ("0", 0), ("100%", 1), ("12,5", 0.125),
        ("37.5", 0.375),
    ])
    func parsesWhatPeopleType(text: String, level: Double) {
        #expect(VolumeLevel.parse(text) == level)
    }

    @Test(arguments: ["", " ", "%", "abc", "100.1", "-1", "1e2", "4 0", "50%%", "0x10", ".", "1.2.3", "½"])
    func rejectsEverythingElse(text: String) {
        #expect(VolumeLevel.parse(text) == nil)
    }

    @Test func stepsLandOnTheGrid() {
        #expect(VolumeLevel.stepped(0.5, divisions: 16, up: true) == 0.5625)
        #expect(VolumeLevel.stepped(0.5, divisions: 16, up: false) == 0.4375)
        #expect(VolumeLevel.stepped(0.52, divisions: 10, up: true) == 0.6)
        #expect(VolumeLevel.stepped(0.52, divisions: 10, up: false) == 0.5)
        #expect(VolumeLevel.stepped(0.5, divisions: 10, up: false) == 0.4, "a grid point moves one whole step")
        #expect(VolumeLevel.stepped(0.3, divisions: 10, up: true) == 0.4)
        #expect(VolumeLevel.stepped(0.97, divisions: 20, up: true) == 1)
        #expect(VolumeLevel.stepped(0.02, divisions: 20, up: false) == 0)
        #expect(VolumeLevel.stepped(1, divisions: 16, up: true) == 1)
    }

    @Test func percentRounds() {
        #expect(VolumeLevel.percent(0.5625) == 56)
        #expect(VolumeLevel.percent(0.4375) == 44)
        #expect(VolumeLevel.percent(1.2) == 100)
    }
}
