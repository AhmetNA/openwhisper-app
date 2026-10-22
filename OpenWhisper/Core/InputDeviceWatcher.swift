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
    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?

    func start(onChange: @escaping () -> Void) {
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
