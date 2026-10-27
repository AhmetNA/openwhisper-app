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
        updateInputPriority(wasConnected: previous)
        updateMicrophoneFlowNotice(initialize: true)
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
        if let pending = pendingWhisperWake, removed.contains(where: { $0.uid == pending.inputUID }) {
            cancelPendingWhisperWake(reason: "wake microphone disconnected", retryDelay: 10)
        }
        syncWakeWordInput()
        let next = resolvedInputDeviceUID(for: nil)
        owLog("[Input] Next recording uses \(availableInputDevices.first { $0.uid == next }?.name ?? "system default")")
    }

    /// Track the selected input, not every device-list event (outputs change too).
    func updateMicrophoneFlowNotice(initialize: Bool = false) {
        guard microphoneNoticeInitialized || initialize else { return }
        let device = MicPriority.top(inputPriorityUIDs, devices: availableInputDevices)
            ?? availableInputDevices.first { $0.isBuiltIn }
            ?? availableInputDevices.first { $0.uid == AudioEngine.defaultInputDeviceUID() }
        let uid = device?.uid
        defer {
            lastNotifiedMicrophoneUID = uid
            microphoneNoticeInitialized = true
        }
        guard microphoneNoticeInitialized, uid != lastNotifiedMicrophoneUID else { return }
        if let device {
            let prefix = recordingState == .recording ? "Sonraki kayıt" : "Mikrofon"
            microphoneFlowNotice = "\(prefix): \(device.name)"
        } else {
            microphoneFlowNotice = "Mikrofon bağlantısı yok"
        }
        presentMicrophoneFlowNotice(microphoneFlowNotice ?? "Mikrofon bağlantısı yok")
    }

    func systemInputDeviceChanged() {
        refreshInputDevices()
        let systemUID = AudioEngine.defaultInputDeviceUID()
        let systemName = availableInputDevices.first { $0.uid == systemUID }?.name ?? "Bağlı mikrofon yok"
        let jarvisUID = resolvedInputDeviceUID(for: nil)
        var message = "Sistem mikrofonu: \(systemName)"
        if jarvisUID != systemUID,
           let jarvisName = availableInputDevices.first(where: { $0.uid == jarvisUID })?.name {
            message += " · Jarvis: \(jarvisName)"
        }
        owLog("[Input] \(message)")
        presentMicrophoneFlowNotice(message)
    }

    private func presentMicrophoneFlowNotice(_ message: String) {
        microphoneFlowNoticeTask?.cancel()
        microphoneFlowNotice = message
        syncFlowBarVisibility()
        microphoneFlowNoticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self else { return }
            self.microphoneFlowNotice = nil
            self.syncFlowBarVisibility()
        }
    }

    /// Stamps the mics connected until now, forgets the ones unseen for three days and puts newly
    /// discovered ones on top; known mics retain their position. The first run builds the list from the old single pick.
    func updateInputPriority(wasConnected previous: [AudioInputDevice]) {
        let seeding = UserDefaults.standard.data(forKey: MicPriority.defaultsKey) == nil
        inputPriority = MicPriority.updated(
            inputPriority, wasConnected: Set(previous.map(\.uid)), connected: availableInputDevices,
            now: Date(), seeding: seeding)
        scheduleInputPriorityExpiry()
    }

    /// Prune absent mics at their deadline even if Core Audio emits no further device events.
    private func scheduleInputPriorityExpiry() {
        inputPriorityExpiryTask?.cancel()
        let connected = Set(availableInputDevices.map(\.uid))
        guard let oldest = inputPriority.filter({ !connected.contains($0.uid) })
            .map(\.lastSeen).min() else {
            inputPriorityExpiryTask = nil
            return
        }
        let delay = max(0.1, oldest.addingTimeInterval(MicPriority.forgetAfter).timeIntervalSinceNow)
        inputPriorityExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refreshInputDevices()
        }
    }

    /// Saved list, or for the first run the mic picked before the list existed.
    static func loadInputPriority(_ defaults: UserDefaults) -> [MicPriorityEntry] {
        if let data = defaults.data(forKey: MicPriority.defaultsKey),
           let list = try? JSONDecoder().decode([MicPriorityEntry].self, from: data) {
            return list
        }
        guard let uid = defaults.string(forKey: "inputDeviceUID") else { return [] }
        let name = defaults.string(forKey: "inputDeviceName") ?? uid
        return [MicPriorityEntry(uid: uid, name: name, isBluetooth: false, lastSeen: Date())]
    }

    /// Moves a mic `offset` places in the list (negative is up).
    func moveInputPriority(uid: String, by offset: Int) {
        guard let index = inputPriority.firstIndex(where: { $0.uid == uid }) else { return }
        let target = index + offset
        guard inputPriority.indices.contains(target) else { return }
        inputPriority.swapAt(index, target)
    }

    /// Points the wake listener at the priority list and, between recordings, moves it to the
    /// mic it should now use. A recording's mic is never switched.
    func syncWakeWordInput() {
        wakeWordListener?.priorityUIDs = inputPriorityUIDs
        guard recordingState != .recording else { return }
        wakeWordListener?.inputDevicesChanged()
    }

    /// The input for a recording started by `trigger`: the highest-ranked connected mic in the
    /// user's list, for every trigger. A confirmation or follow-up stays on the mic of the
    /// session that led to it, so one conversation never changes mic.
    func resolvedInputDeviceUID(for trigger: RecordingTrigger?) -> String? {
        Self.inputDeviceUID(
            priority: inputPriorityUIDs,
            trigger: trigger,
            devices: AudioEngine.availableInputDevices(),
            chainedUID: chainedInputUID
        )
    }

    /// The Mac mic when none of the list is connected (a mic the list hasn't been told about
    /// yet); nil, the system default, only when there's no Mac mic either.
    static func inputDeviceUID(
        priority: [String], trigger: RecordingTrigger?, devices: [AudioInputDevice], chainedUID: String?
    ) -> String? {
        if let trigger, [.confirmation, .followUp].contains(trigger), let chainedUID,
           devices.contains(where: { $0.uid == chainedUID }) {
            return chainedUID
        }
        return MicPriority.top(priority, devices: devices)?.uid ?? devices.first { $0.isBuiltIn }?.uid
    }

    /// The profile a recording is filtered against: buds and external-mic recordings only ever
    /// use their own profile (nil without one, so they stay unfiltered), the Mac mic the Mac one.
    static func sessionTargetSpeakerProfile(
        mic: TargetSpeakerMic, mac: TargetSpeakerProfile?, buds: TargetSpeakerProfile?, external: TargetSpeakerProfile?
    ) -> TargetSpeakerProfile? {
        switch mic {
        case .mac: return mac
        case .buds: return buds
        case .external: return external
        }
    }

    static func inputIsBluetooth(uid: String?) -> Bool {
        guard let uid else { return false }
        return AudioEngine.availableInputDevices().first(where: { $0.uid == uid })?.isBluetooth ?? false
    }
}
