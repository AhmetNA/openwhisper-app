import AudioToolbox
import CoreAudio
import Foundation

/// Where the Mac's sound goes now: headphones or the room, and how loud the system is set.
enum OutputRoute {
    /// Bluetooth audio (AirPods, buds) or something plugged into the headphone jack.
    static func isHeadphones() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let transport: UInt32 = read(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        // The built-in output reports its jack as the 'hdpn' data source.
        let source: UInt32? = read(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return transport == kAudioDeviceTransportTypeBuiltIn && source == 0x6864_706E  // 'hdpn'
    }

    /// The system output volume, 0…1; nil when the device has no volume control.
    static func systemVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        let value: Float32? = read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
            ?? read(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        return value
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        let id: AudioDeviceID? = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                      scope: kAudioObjectPropertyScopeGlobal)
        return id == 0 ? nil : id
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}
