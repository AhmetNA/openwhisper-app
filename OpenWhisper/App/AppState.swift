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
    let pasteContext: PasteContext
    let stream: AsyncStream<CompletedAudioSegment>
    let continuation: AsyncStream<CompletedAudioSegment>.Continuation
    let targetSpeakerEnabled: Bool
    let targetSpeakerProfile: TargetSpeakerProfile?

    var task: Task<Void, Never>?
    var segmentTexts: [String] = []
    /// Every non-empty transcript in segment order. Used only for the explicit ambiguous/no-match
    /// clipboard fallback so a later accepted segment is not lost when an earlier segment is
    /// ambiguous.
    var allSegmentTexts: [String] = []
    /// Text transcribed from audio the target-speaker gate rejected or marked ambiguous (not a
    /// model/profile failure). Kept separate from `segmentTexts` so it cannot enter the normal
    /// paste path without explicit user confirmation.
    var unmatchedSegmentTexts: [String] = []
    /// Original (unfiltered) samples from segments the gate rejected as below-threshold --
    /// accumulated across the whole recording so that, if the *entire* recording is rejected,
    /// the user can explicitly copy the salvaged transcription. Capped at
    /// `TargetSpeakerFilterConfiguration.maximumEnrollmentDuration` worth of samples (keeping the
    /// most recent audio) as segments are appended, so a long recording can't grow this
    /// unbounded. Never populated on the fail-closed path -- see `isBelowThresholdRejection` in
    /// `transcribeStreamingSegment`.
    var belowThresholdRejectedSamples: [Float] = []
    /// Original samples from segments with at least one target-like window but unresolved
    /// uncertainty. These are retained for the explicit user-confirmation fallback, never for
    /// automatic profile learning.
    var ambiguousTargetSamples: [Float] = []
    var hadAmbiguousTargetSpeech = false
    var hadPartialTargetSpeech = false
    var confirmationCandidate: TargetSpeakerConfirmationCandidate?
    var confirmationTranscriptTexts: [String] = []
    var hadSingleSpeakerUncertain = false
    var hadDiarizationAttempt = false
    var hadDiarizationTargetSpeech = false
    var hadDiarizationFailure = false
    var hadDiarizedOverlap = false
    var queuedSampleCount = 0
    var nextSegmentNumber = 0
    var isCancelled = false
    var hasFinished = false
    var acceptedTargetSpeechSamples = 0
    /// True once any segment in this recording hit the fail-closed (model/profile error) path.
    /// `TargetSpeakerOutputGate.shouldSkipPostProcessing` only looks at accepted sample counts,
    /// which stay 0 for a fail-closed segment even though its text landed in `segmentTexts` via
    /// the normal-dictation passthrough -- this flag lets `finishTranscription` know not to
    /// treat that as "nothing matched" and discard/clipboard the text instead of pasting it.
    var hadFailClosedPassthrough = false

    init(
        id: UInt64,
        targetApp: NSRunningApplication?,
        targetSpeakerEnabled: Bool,
        targetSpeakerProfile: TargetSpeakerProfile?,
        pasteContext: PasteContext? = nil
    ) {
        self.id = id
        self.targetApp = targetApp
        self.pasteContext = pasteContext ?? PasteContext.capture(targetApp: targetApp)
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
        didSet {
            UserDefaults.standard.set(targetSpeakerEnabled, forKey: "targetSpeakerEnabled")
            if targetSpeakerEnabled {
                startTargetSpeakerDiarizationPreparation()
            }
        }
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
    /// True while the flow bar shows the "bu benim sesimdi" confirmation offer. Distinct from
    /// `flowBarMessage`'s normal 1.5s auto-dismiss timer (`showFlowBarMessage`) -- this state
    /// has its own, longer-lived 8s timer (`showTargetSpeakerAppendOffer`) so there's enough
    /// time to actually read and tap the control before it disappears.
    var targetSpeakerAppendOfferActive: Bool = false

    /// True only when the in-memory profile matches the currently selected model.
    /// `hasStoredTargetSpeakerProfile` remains true for an incompatible profile so the user
    /// can still replace or delete it.
    var hasTargetSpeakerProfile: Bool {
        targetSpeakerProfile?.isCompatible(with: targetSpeakerModel.modelIdentifier) == true
    }
    var hasStoredTargetSpeakerProfile = false
    /// Current embedding count of the active profile, surfaced in Settings next to
    /// `targetSpeakerProfileStatus` so the user can inspect the controlled enrollment profile.
    var targetSpeakerEmbeddingCount: Int { targetSpeakerProfile?.embeddings.count ?? 0 }
    var canUndoTargetSpeakerAppend: Bool { lastConfirmedAppendReceipt != nil }
    /// Cached (not computed-on-read) coherence of the currently active profile's pooled
    /// embeddings, surfaced in Settings next to the embedding count. Computing this is O(n^2)
    /// pairwise cosine similarities -- at the 300-embedding hard cap that's ~45k comparisons -- so
    /// it is recalculated only when `targetSpeakerProfile` actually changes (see
    /// `refreshTargetSpeakerProfileCoherence`), never from a SwiftUI view body. A pooled
    /// two-posture profile reads lower than either enrollment recording's own coherence, which is
    /// expected -- it is a profile-health signal, not a duplicate of the enrollment-time check.
    var targetSpeakerProfileCoherence: Float?

    // MARK: - Components

    private var audioEngine: AudioEngine?
    private var transcriber: WhisperTranscriber?
    private var llmCleanup: LLMCleanup?
    private var textInjector: TextInjecting? = TextInjector()
    private var hotkey: GlobalHotkey?
    private var flowBarController: FlowBarController?
    private var reminderManager: ReminderManager?
    private var recordingTimer: Timer?
    private var targetApp: NSRunningApplication?
    private let targetSpeakerProfileStore: TargetSpeakerProfileStore
    private let targetSpeakerModel: TargetSpeakerModelProvider
    private let targetSpeakerFilter: TargetSpeakerFilter
    private let targetSpeakerDiarization: TargetSpeakerDiarizationService
    private let injectedTranscriptionService: WhisperTranscriptionService?
    private var targetSpeakerProfile: TargetSpeakerProfile?
    private var targetSpeakerEnrollmentTask: Task<Void, Never>?
    private var targetSpeakerDiarizationPreparationTask: Task<Void, Never>?
    private var targetSpeakerDiarizationReady = false
    private var targetSpeakerEnrollmentGeneration: UInt64 = 0
    private var targetSpeakerEnrollmentRecordings: [[Float]] = []
    private var flowBarMessageTask: Task<Void, Never>?
    private var targetSpeakerAppendOfferTask: Task<Void, Never>?
    /// The exact coherent candidate, transcript, and target captured for the 8-second explicit
    /// confirmation offer. These three values are cleared together on timeout, next recording,
    /// or tap; no rejected/overlap audio is substituted into this path.
    private var retainedConfirmationCandidate: TargetSpeakerConfirmationCandidate?
    private var retainedConfirmationText: String?
    private var retainedConfirmationPasteContext: PasteContext?
    private var retainedConfirmationTargetApp: NSRunningApplication?
    private var confirmationOperationID: UInt64 = 0
    private var isConfirmationInFlight = false
    private var confirmationPasteOutcome: PasteOutcome?
    private var confirmationPasteCompleted = false
    private var confirmationAppendCompleted = false
    private var confirmationAppendSucceeded = false
    private var confirmationAppendError: String?
    private var confirmationTextBeingDelivered = ""
    private var lastConfirmedAppendReceipt: TargetSpeakerProfileAppendReceipt?
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
        transcriptionService: WhisperTranscriptionService? = nil,
        textInjector: TextInjecting? = nil,
        targetSpeakerDiarization: TargetSpeakerDiarizationService = FluidAudioTargetSpeakerDiarizationService()
    ) {
        if let textInjector {
            self.textInjector = textInjector
        }
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
        self.targetSpeakerDiarization = targetSpeakerDiarization
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
        startTargetSpeakerDiarizationPreparation()

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
        refreshTargetSpeakerProfileCoherence()
    }

    /// Recomputes `targetSpeakerProfileCoherence` from the currently active profile. Called
    /// exactly at the points where `targetSpeakerProfile` itself changes (load, enrollment
    /// success and delete) -- never from a view body -- because the underlying
    /// computation is O(n^2) in embedding count. Existing profiles predate this check entirely and
    /// are never retroactively invalidated by a low score here; this is purely informational.
    private func refreshTargetSpeakerProfileCoherence() {
        targetSpeakerProfileCoherence = targetSpeakerProfile.map { TargetSpeakerFilter.recordingCoherence($0.embeddings) }
    }

    /// Starts the optional overlap stack in the background. Normal dictation never awaits this
    /// task: if a download/preparation is still running, the target-speaker filter remains the
    /// conservative path for the current recording and a later recording can use diarization once
    /// preparation has completed.
    private func startTargetSpeakerDiarizationPreparation() {
        guard targetSpeakerEnabled,
              targetSpeakerProfile != nil,
              !targetSpeakerDiarizationReady,
              targetSpeakerDiarizationPreparationTask == nil else { return }

        let progressHandler: TargetSpeakerDiarizationProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, !self.targetSpeakerEnrollmentActive else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
            }
        }
        targetSpeakerDiarizationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.targetSpeakerDiarizationPreparationTask = nil
                if !self.targetSpeakerEnrollmentActive {
                    self.targetSpeakerPreparationProgress = nil
                    self.targetSpeakerPreparationMessage = ""
                }
            }
            do {
                try await self.targetSpeakerDiarization.prepare(progressHandler: progressHandler)
                guard !Task.isCancelled else { return }
                self.targetSpeakerDiarizationReady = true
                owLog("[TargetSpeaker] Diarization preparation ready")
            } catch {
                self.targetSpeakerDiarizationReady = false
                self.lastError = "Ses ayrıştırma modeli hazırlanamadı: \(error.localizedDescription)"
                owLog("[TargetSpeaker] Diarization preparation failed: \(error)")
            }
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
        // and retain the exact editable destination for asynchronous delivery.
        targetApp = NSWorkspace.shared.frontmostApplication
        let pasteContext = PasteContext.capture(targetApp: targetApp)
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
            targetSpeakerProfile: targetSpeakerProfile,
            pasteContext: pasteContext
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
                session.hadFailClosedPassthrough = true
                owLog("[OpenWhisper] Target speaker filter failed closed: \(error)")
            }
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
        } else {
            filtered = TargetSpeakerFilterResult(
                samples: segment.samples,
                acceptedSampleCount: segment.samples.count,
                hadVoiceActivity: true,
                decision: .disabled,
                wasFailClosed: false,
                errorDescription: nil
            )
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
        }

        // Three distinct outcomes once the target-speaker gate is in play -- kept as separate
        // booleans (rather than folded into one branch) so the fail-closed path and the
        // below-threshold path can never accidentally share behavior:
        //   1. wasFailClosed: the gate itself errored (nil/incompatible profile, model
        //      preparation/embedding failure). It made no decision at all, so a transient
        //      failure must not cost the user their dictation -- treat exactly like the
        //      feature-disabled path below.
        //   2. below-threshold rejection: the gate ran fine and decided this isn't the target
        //      speaker. Still transcribe (unless there was no voice at all) so the text can be
        //      salvaged onto the clipboard, but keep it out of `segmentTexts` -- it must never
        //      reach the normal paste/post-processing path.
        //   3. accepted (or feature disabled): existing normal path.
        let isFailClosedPassthrough = session.targetSpeakerEnabled && filtered.wasFailClosed
        let isAmbiguousTargetMatch = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && filtered.decision == .ambiguous
        let isSingleSpeakerUncertain = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && filtered.decision == .singleSpeakerUncertain
        let canUseDiarizationDecision: Bool
        switch filtered.decision {
        case .accepted, .partial, .ambiguous:
            canUseDiarizationDecision = true
        default:
            canUseDiarizationDecision = false
        }
        let shouldUseDiarization = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && targetSpeakerDiarizationReady
            && filtered.hadVoiceActivity
            && canUseDiarizationDecision
        if session.targetSpeakerEnabled && filtered.decision == .partial {
            session.hadPartialTargetSpeech = true
        }
        let isBelowThresholdRejection = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && (filtered.decision == .rejected || filtered.decision == .noVoice)

        if isAmbiguousTargetMatch {
            session.hadAmbiguousTargetSpeech = true
            guard filtered.hadVoiceActivity else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; Whisper skipped")
                return
            }
            guard shouldUseDiarization else {
                owLog("[OpenWhisper] Batch \(segmentNumber) ambiguous speech withheld because diarization is not ready")
                return
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) has unresolved target-speaker ambiguity; trying timed overlap filtering")
        } else if isSingleSpeakerUncertain {
            session.hadSingleSpeakerUncertain = true
            guard let candidate = filtered.confirmationCandidate else {
                owLog("[OpenWhisper] Batch \(segmentNumber) was single-speaker uncertain without a candidate")
                return
            }
            if session.confirmationCandidate == nil {
                session.confirmationCandidate = candidate
            }
            guard filtered.hadVoiceActivity else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; confirmation transcription skipped")
                return
            }
            do {
                let candidateText = try await transcriber.transcribe(
                    audioData: candidate.samples,
                    language: language,
                    overlapSampleCount: segment.overlapSampleCount
                )
                guard !session.isCancelled else { return }
                let trimmedCandidateText = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCandidateText.isEmpty,
                      !trimmedCandidateText.hasPrefix("[BLANK"),
                      !trimmedCandidateText.hasPrefix("(BLANK") else { return }
                session.confirmationTranscriptTexts.append(trimmedCandidateText)
                owLog("[OpenWhisper] Batch \(segmentNumber) retained a single-speaker confirmation candidate")
            } catch {
                owLog("[OpenWhisper] Batch \(segmentNumber) confirmation transcription failed: \(error)")
            }
            return
        } else if isBelowThresholdRejection {
            // Retain the original (unfiltered) audio in case the *whole* recording ends up
            // rejected and needs explicit clipboard fallback. Capped here,
            // streaming-style, at `maximumEnrollmentDuration` worth of samples (keeping the most
            // recent audio) so a long multi-batch recording can't grow this without bound.
            session.belowThresholdRejectedSamples.append(contentsOf: segment.samples)
            let maxRetainedSamples = Int(
                TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                    * Double(TargetSpeakerFilterConfiguration.sampleRate)
            )
            if session.belowThresholdRejectedSamples.count > maxRetainedSamples {
                session.belowThresholdRejectedSamples.removeFirst(
                    session.belowThresholdRejectedSamples.count - maxRetainedSamples
                )
            }
            guard filtered.hadVoiceActivity else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; Whisper skipped")
                return
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) below target-speaker threshold; transcribing for clipboard salvage only")
        } else if isFailClosedPassthrough {
            owLog("[OpenWhisper] Batch \(segmentNumber) target-speaker gate failed closed; transcribing as normal dictation")
        }

        do {
            let segmentText: String
            if shouldUseDiarization {
                do {
                    let timedTranscription = try await transcriber.transcribeTimed(
                        audioData: segment.samples,
                        language: language,
                        overlapSampleCount: segment.overlapSampleCount
                    )
                    guard let profile = session.targetSpeakerProfile else {
                        throw TargetSpeakerDiarizationError.incompatibleProfile(
                            expected: FluidAudioTargetSpeakerDiarizationService.modelIdentifier,
                            actual: "missing"
                        )
                    }
                    session.hadDiarizationAttempt = true
                    let diarized = try await targetSpeakerDiarization.diarizeAndFilter(
                        audioData: segment.samples,
                        transcription: timedTranscription,
                        profile: profile
                    )
                    let diarizedText = diarized.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if diarized.acceptedWordCount > 0,
                       !diarizedText.isEmpty,
                       !diarizedText.hasPrefix("[BLANK"),
                       !diarizedText.hasPrefix("(BLANK") {
                        session.hadDiarizationTargetSpeech = true
                        session.hadDiarizedOverlap = session.hadDiarizedOverlap || diarized.hadOverlap
                        segmentText = diarizedText
                        owLog("[OpenWhisper] Batch \(segmentNumber) diarized target words=\(diarized.acceptedWordCount) overlap=\(diarized.hadOverlap)")
                    } else {
                        owLog("[OpenWhisper] Batch \(segmentNumber) diarization found no safe target words")
                        guard !isAmbiguousTargetMatch,
                              filtered.hasAcceptedTargetSpeech else { return }
                        segmentText = try await transcriber.transcribe(
                            audioData: TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples,
                            language: language,
                            overlapSampleCount: segment.overlapSampleCount
                        )
                    }
                } catch {
                    session.hadDiarizationFailure = true
                    lastError = error.localizedDescription
                    owLog("[OpenWhisper] Batch \(segmentNumber) diarization failed; preserving masked target-speaker safety: \(error)")
                    // A partial result still has a safe identity-masked path. An ambiguous result
                    // has no accepted target samples, so never transcribe its original mixed audio
                    // and never offer it for confirmation.
                    guard !isAmbiguousTargetMatch,
                          filtered.hasAcceptedTargetSpeech else { return }
                    segmentText = try await transcriber.transcribe(
                        audioData: TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples,
                        language: language,
                        overlapSampleCount: segment.overlapSampleCount
                    )
                }
            } else {
                // Fail-closed and below-threshold results transcribe the original only in their
                // established fallback paths. Normal accepted output uses identity-masked audio.
                let samplesToTranscribe: [Float]
                if isFailClosedPassthrough || isBelowThresholdRejection {
                    samplesToTranscribe = segment.samples
                } else {
                    samplesToTranscribe = TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples
                }
                segmentText = try await transcriber.transcribe(
                    audioData: samplesToTranscribe,
                    language: language,
                    overlapSampleCount: segment.overlapSampleCount
                )
            }
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Batch \(segmentNumber) overlap=\(segment.overlapSampleCount) samples text=\(segmentText)")
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.allSegmentTexts.append(segmentText)
            if isBelowThresholdRejection {
                session.unmatchedSegmentTexts.append(segmentText)
            } else {
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
        if !session.hadFailClosedPassthrough,
           session.hadSingleSpeakerUncertain,
           session.segmentTexts.isEmpty,
           let candidate = session.confirmationCandidate {
            let confirmationText = AudioSegmentation.joinTranscripts(session.confirmationTranscriptTexts)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !confirmationText.isEmpty,
                  !confirmationText.hasPrefix("[BLANK"),
                  !confirmationText.hasPrefix("(BLANK") else {
                showFlowBarMessage("Ses kesinleşmedi")
                return
            }
            retainConfirmation(
                candidate: candidate,
                text: confirmationText,
                pasteContext: session.pasteContext,
                targetApp: session.targetApp
            )
            textInjector?.copyToClipboard(confirmationText)
            showTargetSpeakerAppendOffer(message: "Ses kesinleşmedi (panoda)")
            owLog("[OpenWhisper] Single-speaker uncertain candidate retained for explicit confirmation")
            return
        }
        if session.hadDiarizationAttempt && session.segmentTexts.isEmpty {
            showFlowBarMessage(
                session.hadDiarizationFailure
                    ? "Karışık konuşma ayrıştırılamadı — hedef konuşma korundu"
                    : "Hedef konuşma bulunamadı"
            )
            return
        }
        // `hadFailClosedPassthrough` takes priority over the gate: a fail-closed segment's text
        // lives in `segmentTexts` (the normal-dictation path) but never contributes accepted
        // samples, so without this check a recording that only ever failed closed would look
        // identical to "nothing matched" and its text would be discarded instead of pasted.
        if !session.hadFailClosedPassthrough,
           TargetSpeakerOutputGate.shouldSkipPostProcessing(
               featureEnabled: session.targetSpeakerEnabled,
               acceptedSampleCount: session.acceptedTargetSpeechSamples
           ) {
            let unmatchedText = AudioSegmentation.joinTranscripts(session.unmatchedSegmentTexts)
            let trimmedUnmatched = unmatchedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSalvageableText = !trimmedUnmatched.isEmpty
                && !trimmedUnmatched.hasPrefix("[BLANK")
                && !trimmedUnmatched.hasPrefix("(BLANK")
            if hasSalvageableText {
                owLog("[OpenWhisper] No accepted target speech in recording; unmatched transcript copied to clipboard")
                textInjector?.copyToClipboard(trimmedUnmatched)
                showFlowBarMessage("Ses eşleşmedi (panoda)")
            } else {
                owLog("[OpenWhisper] No accepted target speech in recording; all post-processing skipped")
                showFlowBarMessage("Ses eşleşmedi")
            }
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
                let backupText = rawText
                let pastedForLearning = cleanedText
                self.textInjector?.pasteTextResult(
                    cleanedText,
                    targetApp: session.targetApp,
                    context: session.pasteContext
                ) { [weak self] outcome in
                    Task { @MainActor in
                        guard let self else { return }
                        switch outcome {
                        case .pastedVerified, .pastedUnverified:
                            // Swap state and the learning snapshot become authoritative only after
                            // a real paste outcome. The raw backup is intentionally copied after
                            // delivery; a clipboard-only fallback must keep its exact payload.
                            self.swapPair = DictationPair(raw: rawText, cleaned: cleanedText)
                            self.swapTargetApp = session.targetApp
                            self.lastInjectedIsCleaned = true
                            self.lastInjectedText = pastedForLearning
                            self.hotkey?.setSwapAvailable(true)
                            self.textInjector?.copyToClipboard(backupText)
                            DictationSnapshot.shared.capture(
                                pastedText: pastedForLearning,
                                targetApp: session.targetApp
                            )
                            if case .pastedUnverified = outcome {
                                self.showFlowBarMessage("Yapıştırma gönderildi")
                            } else if session.hadDiarizedOverlap {
                                self.showFlowBarMessage("Karışık konuşma ayrıştırıldı")
                            } else {
                                self.showFlowBarMessage(
                                    session.hadDiarizationFailure
                                        ? "Karışık konuşma ayrıştırılamadı — hedef konuşma korundu"
                                        : "Yapıştırıldı"
                                )
                            }
                        case .clipboardOnly(let reason):
                            self.swapPair = nil
                            self.hotkey?.setSwapAvailable(false)
                            self.showFlowBarMessage(self.clipboardOnlyMessage(for: reason))
                        }
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
        confirmationOperationID &+= 1
        isConfirmationInFlight = false
        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = ""
        dismissTargetSpeakerAppendOffer()
        if flowBarMessage != nil {
            flowBarMessage = nil
            syncFlowBarVisibility()
        }
    }

    // MARK: - Target Speaker rejected-recording confirmation

    /// Shows the "bu benim sesimdi" confirmation offer. Deliberately separate from `showFlowBarMessage`: that
    /// helper's 1.5s auto-dismiss is shared by other callers and must not change, whereas a
    /// clickable control needs enough time (8s) to actually be read and tapped. Cancels any
    /// pending `flowBarMessageTask` so a stray 1.5s timer can't yank the message out from under
    /// the offer.
    private func showTargetSpeakerAppendOffer(message: String) {
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        flowBarMessage = message
        targetSpeakerAppendOfferActive = true
        syncFlowBarVisibility()

        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.dismissTargetSpeakerAppendOffer()
            self.flowBarMessage = nil
            self.syncFlowBarVisibility()
        }
    }

    /// Tears down the offer's own state (task, active flag, retained audio + text) without
    /// necessarily touching `flowBarMessage` -- callers that are about to show their own message
    /// right after (e.g. `confirmRetainedRecordingWasTargetSpeaker`) clear that separately.
    /// Internal (not `private`) so tests can simulate the 8s offer timeout firing without an
    /// actual 8-second sleep -- see `AppStateTargetSpeakerIntegrationTests`.
    func dismissTargetSpeakerAppendOffer() {
        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = nil
        targetSpeakerAppendOfferActive = false
        retainedConfirmationCandidate = nil
        retainedConfirmationText = nil
        retainedConfirmationPasteContext = nil
        retainedConfirmationTargetApp = nil
    }

    /// Stores the candidate, transcript, and destination context as one retained confirmation
    /// unit so they can never drift to different recordings.
    private func retainConfirmation(
        candidate: TargetSpeakerConfirmationCandidate,
        text: String,
        pasteContext: PasteContext?,
        targetApp: NSRunningApplication?
    ) {
        guard !candidate.samples.isEmpty, !text.isEmpty else {
            dismissTargetSpeakerAppendOffer()
            return
        }
        retainedConfirmationCandidate = candidate
        retainedConfirmationText = text
        retainedConfirmationPasteContext = pasteContext
        retainedConfirmationTargetApp = targetApp
    }

    /// Fired by the flow bar's "Bu benim sesimdi" tap. It delivers the retained transcript once
    /// and then explicitly appends the retained coherent candidate to the active profile.
    func confirmRetainedRecordingWasTargetSpeaker() {
        guard !isConfirmationInFlight,
              targetSpeakerAppendOfferActive,
              let candidate = retainedConfirmationCandidate,
              let textToPaste = retainedConfirmationText,
              let profile = targetSpeakerProfile else { return }

        let pasteContext = retainedConfirmationPasteContext
        let targetApp = retainedConfirmationTargetApp
        confirmationOperationID &+= 1
        let operationID = confirmationOperationID
        isConfirmationInFlight = true
        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = textToPaste

        // Deactivate the chip before starting either asynchronous operation. Keep the retained
        // triple alive until both delivery and append complete; the in-flight flag prevents a
        // second tap, while a timeout or new recording still clears it atomically.
        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = nil
        targetSpeakerAppendOfferActive = false
        flowBarMessage = "Onay işleniyor…"
        syncFlowBarVisibility()

        // Start delivery before the profile append, using the exact retained PasteContext.
        textInjector?.pasteTextResult(
            textToPaste,
            targetApp: targetApp,
            context: pasteContext
        ) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.confirmationOperationID == operationID else { return }
                self.confirmationPasteOutcome = outcome
                self.confirmationPasteCompleted = true
                self.finishConfirmationOperationIfReady(operationID: operationID)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt = try await self.targetSpeakerFilter.appendConfirmedCandidateWithReceipt(
                    candidate,
                    to: profile,
                    store: self.targetSpeakerProfileStore
                )
                guard self.confirmationOperationID == operationID else { return }
                self.targetSpeakerProfile = receipt.appendedProfile
                self.refreshTargetSpeakerProfileCoherence()
                self.hasStoredTargetSpeakerProfile = true
                self.targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                self.lastConfirmedAppendReceipt = receipt
                self.confirmationAppendSucceeded = true
                self.confirmationAppendError = nil
            } catch {
                guard self.confirmationOperationID == operationID else { return }
                self.confirmationAppendSucceeded = false
                self.confirmationAppendError = error.localizedDescription
                self.lastError = error.localizedDescription
                owLog("[TargetSpeaker] Confirmed candidate append failed: \(error)")
            }
            guard self.confirmationOperationID == operationID else { return }
            self.confirmationAppendCompleted = true
            self.finishConfirmationOperationIfReady(operationID: operationID)
        }
    }

    private func finishConfirmationOperationIfReady(operationID: UInt64) {
        guard isConfirmationInFlight,
              confirmationOperationID == operationID,
              confirmationPasteCompleted,
              confirmationAppendCompleted else { return }

        let pasteOutcome = confirmationPasteOutcome ?? .clipboardOnly(.targetApplicationUnavailable)
        let appendSucceeded = confirmationAppendSucceeded
        let appendError = confirmationAppendError
        isConfirmationInFlight = false
        if !appendSucceeded, let appendError {
            lastError = appendError
        }

        switch (pasteOutcome, appendSucceeded) {
        case (.pastedVerified, true):
            swapPair = nil
            hotkey?.setSwapAvailable(false)
            lastInjectedIsCleaned = true
            lastInjectedText = confirmationTextBeingDelivered
            showFlowBarMessage("Yapıştırıldı — ses profiline eklendi")
        case (.pastedUnverified, true):
            swapPair = nil
            hotkey?.setSwapAvailable(false)
            lastInjectedIsCleaned = true
            lastInjectedText = confirmationTextBeingDelivered
            showFlowBarMessage("Yapıştırma gönderildi — ses profiline eklendi")
        case (.clipboardOnly(_), true):
            showFlowBarMessage("Metin panoda, ses profiline eklendi")
        case (.pastedVerified, false):
            showFlowBarMessage("Yapıştırıldı")
        case (.pastedUnverified, false):
            showFlowBarMessage("Yapıştırma gönderildi")
        case (.clipboardOnly(let reason), false):
            showFlowBarMessage(clipboardOnlyMessage(for: reason))
        }

        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = ""
        dismissTargetSpeakerAppendOffer()
    }

    private func clipboardOnlyMessage(for reason: ClipboardOnlyReason) -> String {
        switch reason {
        case .accessibilityUnavailable:
            return "Yapıştırılamadı — erişim izni gerekli (metin panoda)"
        case .targetApplicationUnavailable, .targetApplicationTerminated, .targetApplicationChanged:
            return "Yapıştırılamadı — hedef uygulama kullanılamıyor (metin panoda)"
        case .noSafeEditableDestination:
            return "Yapıştırılamadı — düzenlenebilir alan bulunamadı (metin panoda)"
        case .activationTimedOut:
            return "Yapıştırılamadı — hedef uygulama etkinleştirilemedi (metin panoda)"
        case .clipboardWriteFailed:
            return "Yapıştırılamadı — pano yazılamadı"
        case .emptyText:
            return "Yapıştırılamadı — metin yok"
        case .pasteEventUnavailable:
            return "Yapıştırılamadı — metin panoda"
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
                    self.refreshTargetSpeakerProfileCoherence()
                    self.hasStoredTargetSpeakerProfile = true
                    self.lastConfirmedAppendReceipt = nil
                    self.targetSpeakerEnabled = true
                    self.startTargetSpeakerDiarizationPreparation()
                    self.targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                    self.targetSpeakerEnrollmentStatus = "Profil hazır; farklı pozisyonlardaki sesin de işlenecek."
                    self.targetSpeakerEnrollmentActive = false
                    self.targetSpeakerPreparationProgress = nil
                } catch {
                    guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                    // `invalidSample`/`crossRecordingMismatch` can only ever implicate the most
                    // recently captured recording (`sampleIndex`), since every earlier recording
                    // already passed this exact validation once before being appended. A
                    // `lowRecordingCoherence` failure is different: it names *which* recording was
                    // contaminated, and that can be an *earlier* one (recording 0's contamination
                    // was never checked until this pass). Falling back to `sampleIndex` there would
                    // discard the wrong (clean) recording and keep the bad one -- an unbreakable
                    // retry loop where redoing the prompted recording can never clear the error.
                    let failedIndex: Int
                    if case TargetSpeakerEnrollmentError.lowRecordingCoherence(let index, _, _) = error {
                        failedIndex = index
                    } else {
                        failedIndex = sampleIndex
                    }
                    self.targetSpeakerEnrollmentStep = failedIndex
                    self.targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[failedIndex]
                    self.targetSpeakerEnrollmentRecordings.removeSubrange(failedIndex...)
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
            refreshTargetSpeakerProfileCoherence()
            hasStoredTargetSpeakerProfile = false
            lastConfirmedAppendReceipt = nil
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

    func undoLastConfirmedTargetSpeakerAppend() {
        guard let receipt = lastConfirmedAppendReceipt else { return }
        do {
            try targetSpeakerFilter.undoConfirmedAppend(receipt, store: targetSpeakerProfileStore)
            targetSpeakerProfile = receipt.previousProfile
            refreshTargetSpeakerProfileCoherence()
            hasStoredTargetSpeakerProfile = true
            targetSpeakerProfileStatus = "Son ekleme geri alındı"
            lastConfirmedAppendReceipt = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            targetSpeakerProfileStatus = error.localizedDescription
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
