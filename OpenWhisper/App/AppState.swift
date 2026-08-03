import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications

/// Owns the audio/transcript state for one dictation. A new recording gets a new session so a
/// later Fn press cannot reset or append to a dictation that is still being transcribed.
@MainActor
final class RecordingTranscriptionSession {
    let id: UInt64
    let targetApp: NSRunningApplication?
    let stream: AsyncStream<CompletedAudioSegment>
    let continuation: AsyncStream<CompletedAudioSegment>.Continuation
    let targetSpeakerEnabled: Bool
    let targetSpeakerProfile: TargetSpeakerProfile?

    var task: Task<Void, Never>?
    var segmentTexts: [String] = []
    var queuedSampleCount = 0
    var nextSegmentNumber = 0
    var isCancelled = false
    var hasFinished = false
    var acceptedTargetSpeechSamples = 0

    init(
        id: UInt64,
        targetApp: NSRunningApplication?,
        targetSpeakerEnabled: Bool,
        targetSpeakerProfile: TargetSpeakerProfile?
    ) {
        self.id = id
        self.targetApp = targetApp
        self.targetSpeakerEnabled = targetSpeakerEnabled
        self.targetSpeakerProfile = targetSpeakerProfile

        var streamContinuation: AsyncStream<CompletedAudioSegment>.Continuation?
        stream = AsyncStream(bufferingPolicy: .unbounded) {
            streamContinuation = $0
        }
        continuation = streamContinuation!
    }

    func enqueue(_ segment: CompletedAudioSegment) {
        queuedSampleCount += segment.samples.count
        continuation.yield(segment)
    }
}

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    // MARK: - Recording State

    enum RecordingState: Sendable, Equatable {
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
    var targetSpeakerEnabled: Bool {
        didSet { UserDefaults.standard.set(targetSpeakerEnabled, forKey: "targetSpeakerEnabled") }
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
    var targetSpeakerProfileStatus: String = "Henüz kayıt yok"
    var targetSpeakerPreparationProgress: Double?
    var targetSpeakerPreparationMessage: String = ""
    var targetSpeakerEnrollmentStep: Int = 0
    var targetSpeakerEnrollmentPrompt: String = ""
    var targetSpeakerEnrollmentActive = false
    var targetSpeakerEnrollmentIsRecording = false
    var targetSpeakerEnrollmentIsProcessing = false
    var targetSpeakerEnrollmentStatus: String = ""
    var flowBarMessage: String?

    /// True only when the in-memory profile matches the currently selected model.
    /// `hasStoredTargetSpeakerProfile` remains true for an incompatible profile so the user
    /// can still replace or delete it.
    var hasTargetSpeakerProfile: Bool {
        targetSpeakerProfile?.isCompatible(with: targetSpeakerModel.modelIdentifier) == true
    }
    var hasStoredTargetSpeakerProfile = false

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
    private let targetSpeakerProfileStore: TargetSpeakerProfileStore
    private let targetSpeakerModel: TargetSpeakerModelProvider
    private let targetSpeakerFilter: TargetSpeakerFilter
    private let injectedTranscriptionService: WhisperTranscriptionService?
    private var targetSpeakerProfile: TargetSpeakerProfile?
    private var targetSpeakerEnrollmentTask: Task<Void, Never>?
    private var targetSpeakerEnrollmentGeneration: UInt64 = 0
    private var targetSpeakerEnrollmentRecordings: [[Float]] = []
    private var flowBarMessageTask: Task<Void, Never>?
    private var activeTranscriptionSession: RecordingTranscriptionSession?
    /// Sessions are transcribed in order, while the microphone can start the next session as
    /// soon as the previous one is stopped.
    private var transcriptionQueueTail: Task<Void, Never>?
    private var transcriptionQueueTailID: UInt64?
    private var nextTranscriptionID: UInt64 = 0
    private var pendingTranscriptionCount = 0

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
    /// The target belonging to the latest raw/cleaned pair, not necessarily the app from the
    /// most recently started recording.
    private var swapTargetApp: NSRunningApplication?

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

    init(
        profileStore: TargetSpeakerProfileStore = KeychainTargetSpeakerProfileStore(),
        targetSpeakerModel: TargetSpeakerModelProvider = FluidAudioTargetSpeakerModel(),
        transcriptionService: WhisperTranscriptionService? = nil
    ) {
        let defaults = UserDefaults.standard
        whisperModel = defaults.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo"
        language = defaults.string(forKey: "language") ?? "tr"
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3:8b"
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        targetSpeakerEnabled = defaults.object(forKey: "targetSpeakerEnabled") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        targetSpeakerProfileStore = profileStore
        self.targetSpeakerModel = targetSpeakerModel
        targetSpeakerFilter = TargetSpeakerFilter(model: targetSpeakerModel)
        injectedTranscriptionService = transcriptionService
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
    }

    private static let targetSpeakerEnrollmentPromptText =
        "Oturur pozisyonda doğal biçimde konuş."

    private static let targetSpeakerEnrollmentConditionPrompts = [
        "Oturur pozisyonda doğal biçimde konuş.",
        "Şimdi pozisyonunu değiştirip, mümkünse yatarak doğal biçimde konuş."
    ]

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

        loadTargetSpeakerProfile()

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

    /// Loads the persisted profile while keeping incompatible profiles available for
    /// replacement/deletion but never active for filtering.
    func loadTargetSpeakerProfile() {
        do {
            targetSpeakerProfile = try targetSpeakerProfileStore.load()
            hasStoredTargetSpeakerProfile = targetSpeakerProfile != nil
            if let profile = targetSpeakerProfile {
                if profile.isCompatible(with: targetSpeakerModel.modelIdentifier) {
                    targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                } else {
                    targetSpeakerProfile = nil
                    targetSpeakerEnabled = false
                    targetSpeakerProfileStatus = "Model sürümü değişti — yeniden kayıt gerekli"
                }
            } else {
                targetSpeakerEnabled = false
            }
        } catch {
            targetSpeakerProfile = nil
            hasStoredTargetSpeakerProfile = false
            targetSpeakerEnabled = false
            targetSpeakerProfileStatus = "Profil okunamadı — yeniden kayıt gerekli"
            lastError = error.localizedDescription
        }
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
        if targetSpeakerEnrollmentActive {
            if targetSpeakerEnrollmentIsRecording {
                stopTargetSpeakerEnrollmentRecording()
            } else {
                startTargetSpeakerEnrollmentRecording()
            }
            return
        }
        // A previous session may still be transcribing. Only an already-active microphone
        // session blocks a new recording.
        guard recordingState != .recording else { return }
        clearFlowBarMessage()
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

        audioEngine?.startRecording(
            deviceUID: inputDeviceUID,
            levelCallback: { [weak self] rawLevel in
                let rms = max(rawLevel, 0.0001)
                let dB = 20 * log10(rms)
                let target = Float(min(max((dB + 48) / 36, 0.0), 1.0))
                Task { @MainActor in
                    guard let self else { return }
                    let factor: Float = target > self.audioLevel ? 0.6 : 0.25
                    self.audioLevel = self.audioLevel + (target - self.audioLevel) * factor
                }
            }
        )

        nextTranscriptionID &+= 1
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: targetApp,
            targetSpeakerEnabled: targetSpeakerEnabled,
            targetSpeakerProfile: targetSpeakerProfile
        )
        activeTranscriptionSession = session
        pendingTranscriptionCount += 1

        let previousTask = transcriptionQueueTail
        let transcriptionTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }

            guard let self else { return }
            for await segment in session.stream {
                if Task.isCancelled || session.isCancelled { break }
                await self.transcribeStreamingSegment(segment, session: session)
            }
            await self.finishTranscription(session)
        }
        session.task = transcriptionTask
        transcriptionQueueTail = transcriptionTask
        transcriptionQueueTailID = session.id

        // Start duration timer and transfer completed three-minute batches to the background
        // transcription queue without stopping or restarting the microphone.
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .recording else { return }
                self.recordingDuration += 0.25
                self.enqueueCompletedAudioSegments()
            }
        }

    }

    func stopRecording() {
        if targetSpeakerEnrollmentIsRecording {
            stopTargetSpeakerEnrollmentRecording()
            return
        }
        guard recordingState == .recording else { return }

        // Restore system output volume immediately when Fn key is released
        AudioDucker.shared.restoreVolume()

        recordingState = .transcribing
        owLog("[OpenWhisper] Finishing recording; waiting for background batches...")

        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioEngine, let session = activeTranscriptionSession else {
            owLog("[OpenWhisper] No audio engine")
            recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
            return
        }
        let segments = audioEngine.stopRecording()

        // Batches already drained during recording are queued before the final tail returned by
        // stopRecording(), so the per-session stream preserves the original recording order.
        for segment in segments {
            enqueueAudioSegment(segment, for: session)
        }
        session.continuation.finish()
        activeTranscriptionSession = nil
    }

    // MARK: - Streaming transcription

    private func enqueueCompletedAudioSegments() {
        guard let audioEngine, let session = activeTranscriptionSession else { return }
        for segment in audioEngine.takeCompletedSegments() {
            enqueueAudioSegment(segment, for: session)
        }
    }

    private func enqueueAudioSegment(_ segment: CompletedAudioSegment, for session: RecordingTranscriptionSession) {
        session.enqueue(segment)
    }

    func transcribeStreamingSegment(
        _ segment: CompletedAudioSegment,
        session: RecordingTranscriptionSession
    ) async {
        guard !session.isCancelled else { return }
        session.nextSegmentNumber += 1
        let segmentNumber = session.nextSegmentNumber

        guard let transcriber = injectedTranscriptionService ?? transcriber else {
            owLog("[OpenWhisper] No transcriber for background batch \(segmentNumber)")
            return
        }

        let filtered: TargetSpeakerFilterResult
        if session.targetSpeakerEnabled {
            filtered = await targetSpeakerFilter.filter(
                samples: segment.samples,
                profile: session.targetSpeakerProfile,
                enabled: true
            )
            if filtered.wasFailClosed, let error = filtered.errorDescription {
                lastError = error
                targetSpeakerProfileStatus = "Filtre hata verdi — bu kayıt işlenmedi"
                owLog("[OpenWhisper] Target speaker filter failed closed: \(error)")
            }
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
            guard filtered.hasAcceptedTargetSpeech else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no accepted target speech; Whisper skipped")
                return
            }
        } else {
            filtered = TargetSpeakerFilterResult(
                samples: segment.samples,
                acceptedSampleCount: segment.samples.count,
                hadVoiceActivity: true,
                wasFailClosed: false,
                errorDescription: nil
            )
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
        }

        do {
            let filteredSegment = TargetSpeakerSegmentFiltering.apply(segment, result: filtered)
            let segmentText = try await transcriber.transcribe(
                audioData: filteredSegment.samples,
                language: language,
                overlapSampleCount: filteredSegment.overlapSampleCount
            )
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Batch \(segmentNumber) overlap=\(segment.overlapSampleCount) samples text=\(segmentText)")
            if !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.segmentTexts.append(segmentText)
            }
        } catch {
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Background batch \(segmentNumber) failed: \(error)")
            lastError = error.localizedDescription
        }
    }

    func finishTranscription(_ session: RecordingTranscriptionSession) async {
        guard !session.hasFinished else { return }
        session.hasFinished = true

        defer {
            // Break the session ↔ worker reference cycle once the worker has drained the
            // session's stream and the final output step is complete.
            session.task = nil
            pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
            if transcriptionQueueTailID == session.id {
                transcriptionQueueTail = nil
                transcriptionQueueTailID = nil
            }
            if recordingState != .recording {
                recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
            }
        }

        guard !session.isCancelled else { return }
        if TargetSpeakerOutputGate.shouldSkipPostProcessing(
            featureEnabled: session.targetSpeakerEnabled,
            acceptedSampleCount: session.acceptedTargetSpeechSamples
        ) {
            owLog("[OpenWhisper] No accepted target speech in recording; all post-processing skipped")
            showFlowBarMessage("Ses eşleşmedi")
            return
        }
        guard session.queuedSampleCount > 4800 else {
            owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples)")
            return
        }

        let text = AudioSegmentation.joinTranscripts(session.segmentTexts)
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
                self.swapTargetApp = session.targetApp
                self.lastInjectedIsCleaned = true
                self.lastInjectedText = cleanedText
                self.hotkey?.setSwapAvailable(true)

                let backupText = rawText
                let pastedForLearning = cleanedText
                self.textInjector?.pasteText(cleanedText, targetApp: session.targetApp) { [weak self] in
                    Task { @MainActor in
                        self?.textInjector?.copyToClipboard(backupText)
                        DictationSnapshot.shared.capture(pastedText: pastedForLearning, targetApp: session.targetApp)
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
            let handled = await SpotifyManager.shared.handleCommand(text: text, targetApp: session.targetApp)
            if handled {
                self.lastTranscription = text
            } else {
                owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                await pasteAsDictation()
            }
        } else {
            await pasteAsDictation()
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
        if recordingState == .idle && flowBarMessage == nil {
            flowBarController?.hide()
        } else {
            flowBarController?.show()
        }
    }

    private func showFlowBarMessage(_ message: String) {
        flowBarMessageTask?.cancel()
        flowBarMessage = message
        syncFlowBarVisibility()
        flowBarMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self else { return }
            self.flowBarMessage = nil
            self.syncFlowBarVisibility()
        }
    }

    private func clearFlowBarMessage() {
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        if flowBarMessage != nil {
            flowBarMessage = nil
            syncFlowBarVisibility()
        }
    }

    // MARK: - Output Swap (Fn+Z)

    /// Whether there's currently a raw/cleaned pair available to swap between — exposed for
    /// UI hinting (e.g. FlowBarView).
    var hasSwappablePair: Bool { swapPair != nil }

    /// Fired the instant a valid Fn+Z gesture is recognized. The recording that started on
    /// this Fn-down is discarded here: no transcription, no injection from it, and the UI
    /// returns to the previous background-transcription state, if any.
    private func cancelRecordingForSwap() {
        guard recordingState == .recording, let session = activeTranscriptionSession else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        session.isCancelled = true
        session.continuation.finish()
        session.task?.cancel()
        activeTranscriptionSession = nil
        _ = audioEngine?.stopRecording()  // discard captured samples — no transcription
        recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
        recordingDuration = 0
        audioLevel = 0
        owLog("[OpenWhisper] Recording cancelled for Fn+Z swap")
    }

    // MARK: - Target Speaker Enrollment

    private func invalidateTargetSpeakerEnrollmentWork() {
        targetSpeakerEnrollmentGeneration &+= 1
        targetSpeakerEnrollmentTask?.cancel()
        targetSpeakerEnrollmentTask = nil
    }

    @discardableResult
    private func teardownTargetSpeakerEnrollmentRecording() -> [Float] {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let samples: [Float]
        if targetSpeakerEnrollmentIsRecording {
            samples = (audioEngine?.stopRecording() ?? []).flatMap(\.samples)
        } else {
            samples = []
        }
        targetSpeakerEnrollmentIsRecording = false
        if recordingState == .recording {
            recordingState = .idle
        }
        recordingDuration = 0
        audioLevel = 0
        return samples
    }

    private func isCurrentTargetSpeakerEnrollment(_ generation: UInt64) -> Bool {
        generation == targetSpeakerEnrollmentGeneration && !Task.isCancelled
    }

    func beginTargetSpeakerEnrollment() {
        guard recordingState == .idle, !targetSpeakerEnrollmentIsProcessing else { return }
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        targetSpeakerEnrollmentActive = true
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        targetSpeakerEnrollmentStep = 0
        targetSpeakerEnrollmentRecordings = []
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[0]
        targetSpeakerEnrollmentStatus = "İki farklı pozisyonda kayıt gerekli; ideal süre her kayıt için 10–15 saniye, maksimum 30 saniye."
    }

    func startTargetSpeakerEnrollmentRecording() {
        guard recordingState == .idle,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              let audioEngine else { return }

        clearFlowBarMessage()

        targetSpeakerEnrollmentIsRecording = true
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        lastError = nil
        audioEngine.startRecording(
            deviceUID: inputDeviceUID,
            levelCallback: { [weak self] rawLevel in
                let rms = max(rawLevel, 0.0001)
                let dB = 20 * log10(rms)
                let target = Float(min(max((dB + 48) / 36, 0.0), 1.0))
                Task { @MainActor in
                    guard let self else { return }
                    self.audioLevel += (target - self.audioLevel) * (target > self.audioLevel ? 0.6 : 0.25)
                }
            }
        )
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.targetSpeakerEnrollmentIsRecording else { return }
                self.recordingDuration = min(
                    self.recordingDuration + 0.25,
                    TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                )
                if self.recordingDuration >= TargetSpeakerFilterConfiguration.maximumEnrollmentDuration {
                    self.stopTargetSpeakerEnrollmentRecording()
                }
            }
        }
    }

    func stopTargetSpeakerEnrollmentRecording() {
        guard targetSpeakerEnrollmentIsRecording else { return }
        let samples = teardownTargetSpeakerEnrollmentRecording()

        guard !samples.isEmpty else {
            targetSpeakerEnrollmentStatus = "Kayıt alınamadı; tekrar deneyin."
            return
        }

        processTargetSpeakerEnrollmentSamples(samples)
    }

    /// Shared enrollment boundary used by the audio path and deterministic state tests.
    func processTargetSpeakerEnrollmentSamples(_ samples: [Float]) {
        guard targetSpeakerEnrollmentActive,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              !samples.isEmpty else { return }

        targetSpeakerEnrollmentIsProcessing = true
        targetSpeakerEnrollmentStatus = "Kayıt doğrulanıyor…"
        let generation = targetSpeakerEnrollmentGeneration
        let progressHandler: TargetSpeakerProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
            }
        }
        let maximumSamples = Int(
            TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                * Double(TargetSpeakerFilterConfiguration.sampleRate)
        )
        let recording = Array(samples.prefix(maximumSamples))
        let sampleIndex = targetSpeakerEnrollmentStep
        targetSpeakerEnrollmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.targetSpeakerEnrollmentGeneration == generation {
                    self.targetSpeakerEnrollmentIsProcessing = false
                    self.targetSpeakerPreparationProgress = nil
                    self.targetSpeakerPreparationMessage = ""
                    self.targetSpeakerEnrollmentTask = nil
                }
            }
            do {
                let result = try await self.targetSpeakerFilter.validateEnrollmentSample(
                    recording,
                    progressHandler: progressHandler
                )
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                guard result.isValid else {
                    self.targetSpeakerEnrollmentStatus = "Bu kayıt en az 10 saniye net konuşma içermiyor veya çok kırpılmış; aynı pozisyonda yeniden kaydedin."
                    return
                }

                guard sampleIndex == self.targetSpeakerEnrollmentRecordings.count else {
                    self.targetSpeakerEnrollmentStatus = "Kayıt sırası değişti; lütfen yeniden başlayın."
                    return
                }
                self.targetSpeakerEnrollmentRecordings.append(recording)

                if self.targetSpeakerEnrollmentRecordings.count < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount {
                    self.targetSpeakerEnrollmentStep += 1
                    self.targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[1]
                    self.targetSpeakerEnrollmentStatus = "İlk kayıt tamamlandı. Duruşunu değiştir ve ikinci kaydı başlat."
                    return
                }

                self.targetSpeakerEnrollmentStep = TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount
                self.targetSpeakerEnrollmentStatus = "İki kayıt doğrulandı; profil çıkarılıyor…"
                do {
                    let profile = try await self.targetSpeakerFilter.createProfile(
                        from: self.targetSpeakerEnrollmentRecordings,
                        store: self.targetSpeakerProfileStore,
                        progressHandler: progressHandler
                    )
                    guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                    self.targetSpeakerProfile = profile
                    self.hasStoredTargetSpeakerProfile = true
                    self.targetSpeakerEnabled = true
                    self.targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                    self.targetSpeakerEnrollmentStatus = "Profil hazır; farklı pozisyonlardaki sesin de işlenecek."
                    self.targetSpeakerEnrollmentActive = false
                    self.targetSpeakerPreparationProgress = nil
                } catch {
                    guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                    self.targetSpeakerEnrollmentStep = sampleIndex
                    self.targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[sampleIndex]
                    self.targetSpeakerEnrollmentRecordings.removeLast()
                    self.targetSpeakerEnrollmentStatus = error.localizedDescription
                    self.lastError = error.localizedDescription
                }
            } catch {
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerEnrollmentStatus = error.localizedDescription
            }
        }
    }

    func cancelTargetSpeakerEnrollment() {
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        targetSpeakerEnrollmentActive = false
        targetSpeakerEnrollmentIsProcessing = false
        targetSpeakerEnrollmentStep = 0
        targetSpeakerEnrollmentRecordings = []
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        targetSpeakerEnrollmentStatus = ""
    }

    func deleteTargetSpeakerProfile() {
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        do {
            try targetSpeakerProfileStore.delete()
            targetSpeakerProfile = nil
            hasStoredTargetSpeakerProfile = false
            targetSpeakerEnabled = false
            targetSpeakerProfileStatus = "Henüz kayıt yok"
            targetSpeakerEnrollmentStatus = "Ses profili silindi."
            targetSpeakerEnrollmentActive = false
            targetSpeakerEnrollmentIsProcessing = false
            targetSpeakerEnrollmentStep = 0
            targetSpeakerEnrollmentRecordings = []
            targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
            targetSpeakerPreparationProgress = nil
            targetSpeakerPreparationMessage = ""
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func replaceTargetSpeakerProfile() {
        guard !targetSpeakerEnrollmentIsProcessing else { return }
        if targetSpeakerEnrollmentIsRecording {
            _ = teardownTargetSpeakerEnrollmentRecording()
        }
        beginTargetSpeakerEnrollment()
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

        textInjector?.replaceInjectedText(oldText: oldText, newText: newText, targetApp: swapTargetApp) { [weak self] in
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
