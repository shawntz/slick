import AudioToolbox
import CoreAudio

/// The real output volume, through Core Audio. Used only when the app runs for a person.
///
/// It acts on the default output device, the one the volume keys change. The volume is the
/// device's virtual main volume, which covers devices that only have per-channel volumes; the HAL
/// answers it through the `AudioObject` calls, so the deprecated Audio Hardware Service functions
/// are not needed. Mute is the device's main mute switch. Neither needs a permission.
nonisolated final class LiveSound: SoundService {
    init() {}

    @concurrent func state() async throws -> SoundState {
        let device = try Self.defaultOutputDevice()
        var volume: Float32 = 0
        var volumeAddress = Self.volumeAddress
        let hasVolume =
            AudioObjectHasProperty(device, &volumeAddress)
            && Self.read(&volume) { size, value in
                AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, size, value)
            }
        var muted: UInt32 = 0
        var muteAddress = Self.muteAddress
        let hasMute =
            AudioObjectHasProperty(device, &muteAddress)
            && Self.read(&muted) { size, value in
                AudioObjectGetPropertyData(device, &muteAddress, 0, nil, size, value)
            }
        return SoundState(volume: hasVolume ? Double(volume) : nil, isMuted: hasMute ? muted != 0 : nil)
    }

    @concurrent func setVolume(_ volume: Double) async throws {
        let device = try Self.defaultOutputDevice()
        var address = Self.volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
            AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
        else {
            throw SystemFailure.unavailable
        }
        var value = Float32(min(1, max(0, volume)))
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw SystemFailure.failed(code: status) }
    }

    @concurrent func setMuted(_ muted: Bool) async throws {
        let device = try Self.defaultOutputDevice()
        var address = Self.muteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
            AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
        else {
            throw SystemFailure.unavailable
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw SystemFailure.failed(code: status) }
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    /// The device sound plays through now. Throws ``SystemFailure/unavailable`` when there is none.
    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        let found = read(&device) { size, value in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, value)
        }
        guard found, device != kAudioObjectUnknown else { throw SystemFailure.unavailable }
        return device
    }

    /// Reads one fixed-size property value. True when the call succeeded.
    private static func read<Value>(
        _ value: inout Value, _ call: (UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
    ) -> Bool {
        var size = UInt32(MemoryLayout<Value>.size)
        return withUnsafeMutablePointer(to: &value) { call(&size, $0) } == noErr
    }
}
