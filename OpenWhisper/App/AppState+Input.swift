import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func refreshPermissions() {
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: false)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (status == .authorized)
    }

    func refreshInputDevices() {
        let previous = availableInputDevices
        availableInputDevices = AudioEngine.availableInputDevices()
        systemDefaultInputIsBluetooth = AudioEngine.systemDefaultInputIsBluetooth()
        if let uid = inputDeviceUID, let name = availableInputDevices.first(where: { $0.uid == uid })?.name {
            UserDefaults.standard.set(name, forKey: "inputDeviceName")
        }
        let added = availableInputDevices.filter { device in !previous.contains { $0.uid == device.uid } }
        let removed = previous.filter { device in !availableInputDevices.contains { $0.uid == device.uid } }
        guard !previous.isEmpty, !(added.isEmpty && removed.isEmpty) else { return }
        owLog("[Input] Devices changed: +[\(added.map(\.name).joined(separator: ", "))] -[\(removed.map(\.name).joined(separator: ", "))]")
        // A dead mic sends no more audio, so voice auto-stop would never fire: end the recording
        // with what it has. The next one picks a connected mic; nothing is switched mid-recording.
        if recordingState == .recording, !targetSpeakerEnrollmentActive, let uid = activeRecordingInputUID,
           removed.contains(where: { $0.uid == uid }) {
            owLog("[Input] Recording mic \(removed.first { $0.uid == uid }?.name ?? uid) disconnected; ending the recording")
            voiceEndpointDetector = nil
            smartTurnEndpointDetector = nil
            ownVoiceStopGate = nil
            hotkey?.externalCancelHandsFree()
            stopRecording()
        }
        // The picked mic stays picked while unplugged; recordings fall back until it returns.
        guard let uid = inputDeviceUID else { return }
        if added.contains(where: { $0.uid == uid }) {
            owLog("[Input] Picked mic \(inputDeviceName ?? uid) is back; next recording uses it")
        } else if removed.contains(where: { $0.uid == uid }) {
            let fallback = resolvedInputDeviceUID(for: nil)
            let name = availableInputDevices.first { $0.uid == fallback }?.name ?? "system default"
            owLog("[Input] Picked mic \(inputDeviceName ?? uid) disconnected; next recording falls back to \(name)")
        }
    }

    /// The input for a recording started by `trigger`. In automatic mode a key-started
    /// recording (Fn, Fn+Space, the shortcut, the Jarvis key) records from connected Bluetooth
    /// buds by UID even while `DefaultInputGuard` keeps the Mac mic as the default. The buds
    /// enter call mode only while that recording runs; stopping it releases their mic, so music
    /// goes back to full quality. A confirmation or follow-up stays on the mic of the session
    /// that led to it. Voice-started sessions keep the default input, which lets them continue
    /// the wake listener's stream.
    func resolvedInputDeviceUID(for trigger: RecordingTrigger?) -> String? {
        Self.inputDeviceUID(
            picked: inputDeviceUID,
            trigger: trigger,
            devices: AudioEngine.availableInputDevices(),
            defaultInputID: AudioEngine.defaultInputDeviceID(),
            chainedBluetoothUID: chainedBluetoothInputUID
        )
    }

    /// A picked mic that is connected always wins. Without one, the automatic rules above
    /// apply; a picked mic that is unplugged falls back to them too, and to the Mac mic when
    /// they would leave the choice to the system default.
    static func inputDeviceUID(
        picked: String?, trigger: RecordingTrigger?, devices: [AudioInputDevice],
        defaultInputID: AudioDeviceID?, chainedBluetoothUID: String?
    ) -> String? {
        if let picked, devices.contains(where: { $0.uid == picked }) { return picked }
        let automatic: String? = {
            if let device = devices.first(where: { $0.id == defaultInputID && $0.isBluetooth }) {
                return device.uid
            }
            guard let trigger else { return nil }
            if keyStartedTriggers.contains(trigger) {
                return devices.first { $0.isBluetooth }?.uid
            }
            if [.confirmation, .followUp].contains(trigger), let uid = chainedBluetoothUID,
               devices.contains(where: { $0.uid == uid }) {
                return uid
            }
            return nil
        }()
        guard picked != nil else { return automatic }
        return automatic ?? devices.first { $0.isBuiltIn }?.uid
    }

    /// The profile a recording is filtered against: buds recordings only ever use the buds
    /// profile (nil without one, so they stay unfiltered), everything else the Mac profile.
    static func sessionTargetSpeakerProfile(
        inputIsBluetooth: Bool, mac: TargetSpeakerProfile?, buds: TargetSpeakerProfile?
    ) -> TargetSpeakerProfile? {
        inputIsBluetooth ? buds : mac
    }

    static func inputIsBluetooth(uid: String?) -> Bool {
        guard let uid else { return false }
        return AudioEngine.availableInputDevices().first(where: { $0.uid == uid })?.isBluetooth ?? false
    }
}
