import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    // MARK: - Recording State

    enum RecordingState: Sendable {
        case idle, recording, transcribing
    }

    var recordingState: RecordingState = .idle {
        didSet {
            guard oldValue != recordingState else { return }
            syncFlowBarVisibility()
        }
    }

    // MARK: - Settings (persisted via UserDefaults)

    var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var llmCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(llmCleanupEnabled, forKey: "llmCleanupEnabled") }
    }
    var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
            llmCleanup = LLMCleanup(model: ollamaModel)
        }
    }
    var flowBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(flowBarEnabled, forKey: "flowBarEnabled")
            syncFlowBarVisibility()
        }
    }
    var autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                owLog("[OpenWhisper] Launch at login error: \(error)")
            }
        }
    }
    /// Persistent UID of the chosen input device. `nil` means "follow system default".
    var inputDeviceUID: String? {
        didSet {
            if let uid = inputDeviceUID {
                UserDefaults.standard.set(uid, forKey: "inputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "inputDeviceUID")
            }
        }
    }

    // MARK: - Runtime State

    var availableInputDevices: [AudioInputDevice] = []
    var systemDefaultInputIsBluetooth: Bool = false

    var audioLevel: Float = 0.0
    var recordingDuration: TimeInterval = 0.0
    var ollamaAvailable: Bool = false
    var modelLoaded: Bool = false
    var modelLoading: Bool = false
    var modelLoadProgress: Double = 0.0
    var modelIsDownloading: Bool = false
    var lastTranscription: String = ""
    var lastError: String?
    var accessibilityGranted: Bool = false
    var microphoneGranted: Bool = false

    // MARK: - Components

    private var audioEngine: AudioEngine?
    private var transcriber: WhisperTranscriber?
    private var llmCleanup: LLMCleanup?
    private var textInjector: TextInjector?
    private var hotkey: GlobalHotkey?
    private var flowBarController: FlowBarController?
    private var reminderManager: ReminderManager?
    private var recordingTimer: Timer?
    private var targetApp: NSRunningApplication?

    // MARK: - Output Swap State

    /// The raw Whisper transcript and LLM-cleaned text from the most recently completed
    /// (and actually pasted) dictation, kept around so Fn+Z can swap between them.
    private struct DictationPair {
        let raw: String
        let cleaned: String
    }
    private var swapPair: DictationPair?
    /// Which version is currently sitting at the cursor.
    private var lastInjectedIsCleaned: Bool = true
    /// The exact string currently injected (post-trim, matching what TextInjector actually
    /// pasted) — its `count` drives how many backspaces a swap sends.
    private var lastInjectedText: String = ""

    // MARK: - Computed

    var menuBarIcon: String {
        switch recordingState {
        case .idle: "mic.fill"
        case .recording: "waveform"
        case .transcribing: "waveform.path.ecg"
        }
    }

    var menuBarIconColor: Color {
        switch recordingState {
        case .idle: .gray
        case .recording: .red
        case .transcribing: .orange
        }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        whisperModel = defaults.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo"
        language = defaults.string(forKey: "language") ?? "tr"
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3:8b"
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
    }

    // MARK: - Setup

    func setup() async {
        owLog("[OpenWhisper] Setting up...")
        if launchAtLogin && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        audioEngine = AudioEngine()
        transcriber = WhisperTranscriber()
        llmCleanup = LLMCleanup(model: ollamaModel)
        textInjector = TextInjector()
        flowBarController = FlowBarController(appState: self)
        syncFlowBarVisibility()

        // Request mic permission
        microphoneGranted = await audioEngine?.requestPermission() ?? false
        owLog("[OpenWhisper] Microphone permission: \(microphoneGranted)")

        // Enumerate input devices for the picker + BT detection
        refreshInputDevices()
        owLog("[OpenWhisper] Input devices: \(availableInputDevices.count), default-is-BT: \(systemDefaultInputIsBluetooth)")

        // Check accessibility
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: true)
        owLog("[OpenWhisper] Accessibility: \(accessibilityGranted)")

        // Register global hotkey
        hotkey = GlobalHotkey(
            onPress: { [weak self] in
                Task { @MainActor in self?.startRecording() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.stopRecording() }
            },
            onSwapRequest: { [weak self] in
                Task { @MainActor in self?.cancelRecordingForSwap() }
            },
            onSwapCommit: { [weak self] in
                Task { @MainActor in self?.commitSwap() }
            },
            onDiagnosticProbe: {
                // TEMPORARY: AX-readability diagnostic. Dispatched off the CGEventTap callback
                // thread (same reasoning as TextInjector's backspace burst): cross-process AX
                // calls to a slow/unresponsive target app can block for a while, and running
                // that inline in the tap callback risks macOS force-disabling the tap
                // (tapDisabledByTimeout), which would drop Fn/Space/Option+Z events meanwhile.
                DispatchQueue.global(qos: .userInitiated).async {
                    AXProbe.run()
                }
            },
            onCorrectionReview: { [weak self] in
                Task { @MainActor in
                    guard self != nil else { return }
                    DictationSnapshot.shared.reviewCurrentDifference()
                    owLog("[OpenWhisper] Manual correction review requested (⌥⇧C)")
                }
            }
        )
        hotkey?.register()
        owLog("[OpenWhisper] Hotkey registered (Fn/Globe)")

        // Load Whisper model
        owLog("[OpenWhisper] Loading model: \(whisperModel)...")
        await loadModel()
        owLog("[OpenWhisper] Model loaded: \(modelLoaded)")

        // Check Ollama availability
        ollamaAvailable = await LLMCleanup.checkAvailability()
        owLog("[OpenWhisper] Ollama available: \(ollamaAvailable)")

        // Setup reminders
        reminderManager = ReminderManager.shared
        let notifGranted = await reminderManager?.requestPermission() ?? false
        owLog("[OpenWhisper] Notification permission: \(notifGranted)")
        owLog("[OpenWhisper] Ready!")
    }

    func loadModel() async {
        modelLoaded = false
        modelLoading = true
        modelLoadProgress = 0
        modelIsDownloading = !(transcriber?.isModelDownloaded(name: whisperModel) ?? false)
        owLog("[OpenWhisper] Loading model: \(whisperModel) (download needed: \(modelIsDownloading))...")
        do {
            try await transcriber?.loadModel(name: whisperModel) { [weak self] progress in
                Task { @MainActor in
                    self?.modelLoadProgress = progress
                }
            }
            modelLoaded = true
            modelLoading = false
            owLog("[OpenWhisper] Model loaded: \(modelLoaded)")
        } catch {
            modelLoading = false
            lastError = "Failed to load model: \(error.localizedDescription)"
            owLog("[OpenWhisper] Model load failed: \(error)")
        }
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard recordingState == .idle else { return }
        guard modelLoaded else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }

        // If a previous dictation's field is still pending a re-read/diff, do that FIRST —
        // otherwise this new dictation's own (much larger) edit to the same field would look
        // like one giant "correction" of the old one. See DictationSnapshot.swift.
        DictationSnapshot.shared.handleNewDictationStarting()

        // Save the currently focused app BEFORE we start recording,
        // so we can re-activate it when pasting the transcription
        targetApp = NSWorkspace.shared.frontmostApplication
        owLog("[OpenWhisper] Target app: \(targetApp?.localizedName ?? "unknown")")

        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil

        // Lower system output volume to 15% while holding dictation hotkey
        AudioDucker.shared.duckVolume(targetVolume: 15)

        audioEngine?.startRecording(deviceUID: inputDeviceUID) { [weak self] rawLevel in
            let rms = max(rawLevel, 0.0001)
            let dB = 20 * log10(rms)
            let target = Float(min(max((dB + 48) / 36, 0.0), 1.0))
            Task { @MainActor in
                guard let self else { return }
                let factor: Float = target > self.audioLevel ? 0.6 : 0.25
                self.audioLevel = self.audioLevel + (target - self.audioLevel) * factor
            }
        }

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
            }
        }

    }

    func stopRecording() {
        guard recordingState == .recording else { return }

        // Restore system output volume immediately when Fn key is released
        AudioDucker.shared.restoreVolume()

        recordingState = .transcribing
        owLog("[OpenWhisper] Transcribing...")

        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioData = audioEngine?.stopRecording() else {
            owLog("[OpenWhisper] No audio captured")
            recordingState = .idle
            return
        }

        guard audioData.count > 4800 else {
            owLog("[OpenWhisper] Audio too short (\(audioData.count) samples)")
            recordingState = .idle
            return
        }

        Task { @MainActor in
            defer {
                self.recordingState = .idle
            }
            do {
                let text = try await self.transcriber?.transcribe(
                    audioData: audioData,
                    language: language
                ) ?? ""

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("[BLANK"),
                      !trimmed.hasPrefix("(BLANK") else {
                    owLog("[OpenWhisper] Empty/blank transcription, skipping")
                    return
                }

                owLog("[OpenWhisper] Raw: \(text)")

                let isReminderCommand = ReminderManager.isReminder(text)
                let isSpotifyCommand = await SpotifyManager.isSpotifyCommand(text, ollamaAvailable: self.ollamaAvailable)

                @MainActor
                func pasteAsDictation() async {
                    let rawText = trimmed
                    var cleanedText = rawText
                    if self.llmCleanupEnabled && self.ollamaAvailable {
                        cleanedText = await self.llmCleanup?.cleanup(text: rawText) ?? rawText
                        owLog("[OpenWhisper] Cleaned: \(cleanedText)")
                    }

                    let activePairs = CorrectionStore.shared.activePairs
                    if !activePairs.isEmpty {
                        let (corrected, applied) = CorrectionEngine.applyCorrections(to: cleanedText, pairs: activePairs)
                        if !applied.isEmpty {
                            cleanedText = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                            for (wrong, right) in applied {
                                owLog("[Corrections] Applied learned correction: \(wrong) -> \(right)")
                            }
                        }
                    }

                    self.lastTranscription = cleanedText

                    if self.autoPasteEnabled {
                        self.swapPair = DictationPair(raw: rawText, cleaned: cleanedText)
                        self.lastInjectedIsCleaned = true
                        self.lastInjectedText = cleanedText
                        self.hotkey?.setSwapAvailable(true)

                        let backupText = rawText
                        let pastedForLearning = cleanedText
                        let pasteTargetApp = self.targetApp
                        self.textInjector?.pasteText(cleanedText, targetApp: self.targetApp) { [weak self] in
                            Task { @MainActor in
                                self?.textInjector?.copyToClipboard(backupText)
                                DictationSnapshot.shared.capture(pastedText: pastedForLearning, targetApp: pasteTargetApp)
                            }
                        }
                    } else {
                        self.textInjector?.copyToClipboard(cleanedText)
                    }
                }

                if isReminderCommand {
                    owLog("[OpenWhisper] Reminder detected: \(text)")
                    self.lastTranscription = text
                    if self.ollamaAvailable {
                        let _ = await self.reminderManager?.handleReminder(text: text)
                    } else {
                        owLog("[OpenWhisper] Cannot set reminder — Ollama not available")
                    }
                } else if isSpotifyCommand {
                    owLog("[OpenWhisper] Spotify command detected: \(text)")
                    let handled = await SpotifyManager.shared.handleCommand(text: text, targetApp: self.targetApp)
                    if handled {
                        self.lastTranscription = text
                    } else {
                        owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                        await pasteAsDictation()
                    }
                } else {
                    await pasteAsDictation()
                }
            } catch {
                owLog("[OpenWhisper] Error: \(error)")
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Flow Bar Visibility

    /// The flow bar is invisible while idle and only appears for the duration of an active
    /// dictation (recording through transcribing/pasting), so the app runs invisibly in the
    /// background otherwise — the menu bar icon remains the only always-visible element.
    private func syncFlowBarVisibility() {
        guard flowBarEnabled else {
            flowBarController?.hide()
            return
        }
        if recordingState == .idle {
            flowBarController?.hide()
        } else {
            flowBarController?.show()
        }
    }

    // MARK: - Output Swap (Fn+Z)

    /// Whether there's currently a raw/cleaned pair available to swap between — exposed for
    /// UI hinting (e.g. FlowBarView).
    var hasSwappablePair: Bool { swapPair != nil }

    /// Fired the instant a valid Fn+Z gesture is recognized. The recording that started on
    /// this Fn-down is discarded here: no transcription, no injection from it, and the UI
    /// drops straight back to idle (the flow bar hides via recordingState's didSet).
    private func cancelRecordingForSwap() {
        guard recordingState == .recording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        _ = audioEngine?.stopRecording()  // discard captured samples — no transcription
        recordingState = .idle
        recordingDuration = 0
        audioLevel = 0
        owLog("[OpenWhisper] Recording cancelled for Fn+Z swap")
    }

    private var isSwapping: Bool = false

    /// Fired whenever Option+Z is pressed. Deletes the currently injected text at the cursor
    /// and replaces it with the other (Ollama öncesi raw ↔ Ollama sonrası cleaned) version.
    /// Repeatable toggle — each call erases the current text and pastes the alternate version.
    private func commitSwap() {
        guard let pair = swapPair, !isSwapping else { return }
        isSwapping = true

        // The raw<->cleaned toggle is not a user "correction" — it's our own swap — so any
        // pending snapshot for the text about to be replaced must be dropped, not diffed.
        DictationSnapshot.shared.invalidateForSwap()

        let newIsCleaned = !lastInjectedIsCleaned
        let newText = newIsCleaned ? pair.cleaned : pair.raw
        let oldText = lastInjectedText
        let backupText = newIsCleaned ? pair.raw : pair.cleaned

        textInjector?.replaceInjectedText(oldText: oldText, newText: newText, targetApp: targetApp) { [weak self] in
            Task { @MainActor in
                self?.textInjector?.copyToClipboard(backupText)
                self?.isSwapping = false
            }
        }

        lastInjectedIsCleaned = newIsCleaned
        lastInjectedText = newText
        owLog("[OpenWhisper] Swap committed — toggle to \(newIsCleaned ? "Ollama sonrası (cleaned)" : "Ollama öncesi (raw)") text")
    }

    // MARK: - Refresh

    func refreshPermissions() {
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: false)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (status == .authorized)
    }

    func refreshInputDevices() {
        availableInputDevices = AudioEngine.availableInputDevices()
        systemDefaultInputIsBluetooth = AudioEngine.systemDefaultInputIsBluetooth()
        // If the previously selected device is no longer present, fall back to system default
        if let uid = inputDeviceUID, !availableInputDevices.contains(where: { $0.uid == uid }) {
            inputDeviceUID = nil
        }
    }

    /// Returns true when dictation will route through a Bluetooth device — i.e. either
    /// the user explicitly picked one, or "System Default" is currently a BT device.
    var resolvedInputIsBluetooth: Bool {
        if let uid = inputDeviceUID {
            return availableInputDevices.first(where: { $0.uid == uid })?.isBluetooth ?? false
        }
        return systemDefaultInputIsBluetooth
    }

    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
    }
}
