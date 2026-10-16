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
        availableInputDevices = AudioEngine.availableInputDevices()
        systemDefaultInputIsBluetooth = AudioEngine.systemDefaultInputIsBluetooth()
        // If the previously selected device is no longer present, automatic mode resolves the
        // next recording to a connected headset or the built-in Mac microphone.
        if let uid = inputDeviceUID, !availableInputDevices.contains(where: { $0.uid == uid }) {
            inputDeviceUID = nil
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
        guard let inputDeviceUID else {
            if let uid = AudioEngine.systemDefaultBluetoothInput()?.uid { return uid }
            guard let trigger else { return nil }
            if Self.keyStartedTriggers.contains(trigger) {
                return AudioEngine.connectedBluetoothInput()?.uid
            }
            if [.confirmation, .followUp].contains(trigger), let uid = chainedBluetoothInputUID,
               AudioEngine.audioDeviceID(forUID: uid) != nil {
                return uid
            }
            return nil
        }
        let devices = AudioEngine.availableInputDevices()
        if devices.contains(where: { $0.uid == inputDeviceUID }) {
            return inputDeviceUID
        }
        return AudioEngine.automaticInputDeviceUID()
    }

    static func inputIsBluetooth(uid: String?) -> Bool {
        guard let uid else { return false }
        return AudioEngine.availableInputDevices().first(where: { $0.uid == uid })?.isBluetooth ?? false
    }
}
