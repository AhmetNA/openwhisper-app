import CoreAudio
import Foundation

/// macOS makes a Bluetooth headset the system default input as soon as it connects. Any app
/// that then opens the microphone puts the buds in call mode (HFP: mono, 16 kHz), so music
/// and video sound muffled. This moves the default input back to the built-in mic whenever
/// it becomes a Bluetooth device. Event-driven: a Core Audio listener, no polling.
final class DefaultInputGuard {
    static let shared = DefaultInputGuard()
    static let defaultsKey = "keepBuiltInMicAsDefaultInput"

    /// On unless turned off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.enforce() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else {
            owLog("[InputGuard] Could not listen for default input changes: \(status)")
            return
        }
        listener = block
        enforce()
    }

    /// Call after the setting is turned on, so a headset that is already the default moves now.
    func enforce() {
        guard Self.isEnabled, AudioEngine.systemDefaultInputIsBluetooth(),
              let builtIn = AudioEngine.availableInputDevices().first(where: { $0.isBuiltIn })
        else { return }
        var id = builtIn.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        owLog("[InputGuard] Bluetooth became the default input; moved to \(builtIn.name) (\(status == noErr ? "ok" : "error \(status)"))")
    }
}
