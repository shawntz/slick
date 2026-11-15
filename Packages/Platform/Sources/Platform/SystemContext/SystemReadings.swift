import AppKit
import CoreAudio
import Foundation
import IOKit.ps
import KitHosting

/// Read-only probes of the Mac's state. None of them prompts.
nonisolated enum SystemReadings {
    /// True when the Mac draws power from its battery.
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// Connected displays, at least 1.
    @MainActor static func displayCount() -> Int {
        max(1, NSScreen.screens.count)
    }

    /// Where sound plays now.
    static func audioRoute() -> SystemContext.AudioRoute {
        guard let device = defaultOutputDevice() else { return .unknown }
        let transport = property(kAudioDevicePropertyTransportType, of: device, scope: kAudioObjectPropertyScopeGlobal)
        let source = property(kAudioDevicePropertyDataSource, of: device, scope: kAudioDevicePropertyScopeOutput)
        return audioRoute(transport: transport ?? 0, dataSource: source)
    }

    /// The data source of built-in output with headphones plugged in, "hdpn".
    static let headphonesDataSource: UInt32 = 0x6864_706E

    /// The route for a device's transport type and data source.
    static func audioRoute(transport: UInt32, dataSource: UInt32?) -> SystemContext.AudioRoute {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            dataSource == headphonesDataSource ? .headphones : .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            .bluetooth
        case kAudioDeviceTransportTypeUnknown:
            .unknown
        default:
            .external
        }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let device = property(
            kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject),
            scope: kAudioObjectPropertyScopeGlobal)
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// A 32-bit property of an audio object, or nil when the object does not have it.
    static func property(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
