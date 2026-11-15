import Foundation
import Kit
import KitTesting
import Testing

@testable import SystemCommands

/// The feature over simulated services, one per group, so every command runs and nothing reaches
/// the Mac.
@MainActor
struct SystemHarness {
    let power = SimulatedPower()
    let housekeeping: SimulatedHousekeeping
    let appearance: SimulatedAppearance
    let sound: SimulatedSound
    let processes: SimulatedProcessTable
    let harness: FeatureHarness<SystemFeature>

    init(
        trashItems: Int = 0, volumeTrashItems: Int = 0, disks: [Disk] = [], isDark: Bool = false,
        sound state: SoundState? = SoundState(volume: 0.5, isMuted: false), processes: [ProcessSample] = [],
        rates: [Int32: Double] = [:], ownPID: Int32 = 99, permissions: PermissionStatus = .granted
    ) {
        housekeeping = SimulatedHousekeeping(trashItems: trashItems, volumeTrashItems: volumeTrashItems, disks: disks)
        appearance = SimulatedAppearance(isDark: isDark)
        sound = SimulatedSound(state)
        self.processes = SimulatedProcessTable(processes, rates: rates, ownPID: ownPID)
        let fakes = FakeServices(permissions: permissions)
        fakes.override(PowerServiceKey.self, with: power)
        fakes.override(HousekeepingServiceKey.self, with: housekeeping)
        fakes.override(AppearanceServiceKey.self, with: appearance)
        fakes.override(SoundServiceKey.self, with: sound)
        fakes.override(ProcessTableKey.self, with: self.processes)
        harness = FeatureHarness(SystemFeature.self, fakes: fakes)
    }

    var fakes: FakeServices { harness.fakes }
    var settings: FeatureSettings { harness.context.settings }

    /// The failure HUD titles, after a command ran with the panel closed.
    var failureHUDs: [String] { harness.huds.filter { $0.style == .failure }.map(\.title) }

    /// Runs a command with errors shown as the host shows them, rather than thrown to the test.
    @discardableResult
    func runShowingErrors(_ id: String, arguments: [String: String] = [:]) async throws -> ActionOutcome {
        harness.throwsActionErrors = false
        defer { harness.throwsActionErrors = true }
        return try await harness.run(id, arguments: arguments)
    }

    static let drive = Disk(name: "Example Drive", path: "/Volumes/Example Drive", isNetwork: false)
    static let backup = Disk(name: "Example Backup", path: "/Volumes/Example Backup", isNetwork: false)
    static let server = Disk(name: "Example Server", path: "/Volumes/Example Server", isNetwork: true)
}
