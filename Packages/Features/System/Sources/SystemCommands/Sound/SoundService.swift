import Foundation
import Kit
import Synchronization

/// The default output device's volume and mute state.
nonisolated struct SoundState: Hashable, Sendable {
    /// From 0 to 1. Nil when the device has no volume control, such as some display speakers.
    var volume: Double?
    /// Nil when the device cannot be muted.
    var isMuted: Bool?
}

/// The volume and mute switch of the device that sound plays through, as the volume keys change them.
///
/// Tests, scenarios, self-tests and benchmarks get ``SimulatedSound``, so they never change the
/// Mac's volume.
nonisolated protocol SoundService: Sendable {
    /// Throws ``SystemFailure/unavailable`` when there is no output device.
    @concurrent func state() async throws -> SoundState
    /// Sets the volume, from 0 to 1.
    @concurrent func setVolume(_ volume: Double) async throws
    @concurrent func setMuted(_ muted: Bool) async throws
}

/// The sound service for each kind of run.
nonisolated enum SoundServiceKey: FeatureServiceKey {
    static func live(_ context: FeatureContext) -> any SoundService {
        LiveSound()
    }

    static func isolated(_ context: FeatureContext) -> any SoundService {
        SimulatedSound(SoundState(volume: 0.5, isMuted: false))
    }
}

/// An output device that exists only in memory. A nil state means there is no device at all.
nonisolated final class SimulatedSound: SoundService {
    private let current: Mutex<SoundState?>

    init(_ state: SoundState?) {
        current = Mutex(state)
    }

    /// The device's state now.
    var device: SoundState? { current.withLock { $0 } }

    func state() async throws -> SoundState {
        guard let state = current.withLock({ $0 }) else { throw SystemFailure.unavailable }
        return state
    }

    func setVolume(_ volume: Double) async throws {
        try current.withLock { state in
            guard state?.volume != nil else { throw SystemFailure.unavailable }
            state?.volume = min(1, max(0, volume))
        }
    }

    func setMuted(_ muted: Bool) async throws {
        try current.withLock { state in
            guard state?.isMuted != nil else { throw SystemFailure.unavailable }
            state?.isMuted = muted
        }
    }
}
