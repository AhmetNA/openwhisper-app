import CoreAudio
import Foundation

/// Calls `onChange` when an audio device is plugged in or removed, so the mic list and the
/// picked-mic fallback stay current. Event-driven: a Core Audio listener, no polling. One plug
/// fires several notifications; they are coalesced into a single call.
final class InputDeviceWatcher {
    static let shared = InputDeviceWatcher()

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var pendingDefaultInput: DispatchWorkItem?
    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?

    func start(onDefaultInputChange: @escaping () -> Void, onChange: @escaping () -> Void) {
        if defaultInputListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.pendingDefaultInput?.cancel()
                let work = DispatchWorkItem(block: onDefaultInputChange)
                self.pendingDefaultInput = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, DispatchQueue.main, block)
            if status == noErr {
                defaultInputListener = block
            } else {
                owLog("[Input] Could not listen for default input changes: \(status)")
            }
        }
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else {
            owLog("[Input] Could not listen for device changes: \(status)")
            return
        }
        listener = block
    }
}
