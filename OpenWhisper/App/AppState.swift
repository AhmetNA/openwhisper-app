import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore

/// Owns the audio/transcript state for one dictation. A new recording gets a new session so a
/// later Fn press cannot reset or append to a dictation that is still being transcribed.
@MainActor
final class RecordingTranscriptionSession {
    let id: UInt64
    let targetApp: NSRunningApplication?
    var pasteContext: PasteContext
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
    /// Set when the first below-threshold rejection is detected so the UI can show
    /// "Ses eşleşmedi" immediately without waiting for Whisper transcription.
    var earlyRejectionShown = false
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
    var audioProcessingMode: AudioProcessingMode {
        didSet { UserDefaults.standard.set(audioProcessingMode.rawValue, forKey: "audioProcessingMode") }
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
            owLog("[TargetSpeaker] targetSpeakerEnabled changed to \(targetSpeakerEnabled)")
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
    var audioDuckingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioDuckingEnabled, forKey: "audioDuckingEnabled")
            syncAudioDuckerConfiguration()
        }
    }
    var audioDuckingTargetVolume: Float {
        didSet {
            UserDefaults.standard.set(audioDuckingTargetVolume, forKey: "audioDuckingTargetVolume")
            syncAudioDuckerConfiguration()
        }
    }
    var audioDuckingRestoreDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(audioDuckingRestoreDuration, forKey: "audioDuckingRestoreDuration")
            syncAudioDuckerConfiguration()
        }
    }

    private func syncAudioDuckerConfiguration() {
        AudioDucker.shared.updateConfiguration(
            targetVolume: audioDuckingTargetVolume,
            restoreDuration: audioDuckingRestoreDuration
        )
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
        targetSpeakerProfile?.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) == true
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
    private var delayedStopWorkItem: DispatchWorkItem?

    /// Whether any background transcription task (other than the currently recording session) is running.
    var isTranscribing: Bool {
        activeTranscriptionSession != nil ? pendingTranscriptionCount > 1 : pendingTranscriptionCount > 0
    }

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
        // Captured before this initializer's own reads/writes touch UserDefaults (in particular
        // before the `whisperModel` line below, whose didSet immediately persists a value even
        // on a first-ever launch) -- true only when nothing has ever been saved for this app,
        // used below to pick DeepFilterNet as the fresh-install default.
        let isFreshInstall = defaults.object(forKey: "whisperModel") == nil
        whisperModel = defaults.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo"
        language = defaults.string(forKey: "language") ?? "tr"
        if defaults.object(forKey: "voiceProcessingMigrationV1") == nil {
            // Ölçüm: setVoiceProcessingEnabled(true) tek başına ~900-1080ms gecikme ekliyor
            // (Fn->ilk ses buffer'ı 1072-1286ms -> 162-207ms). Depolanmış eski `true` değeri
            // kod varsayılanını (false) eziyor, bu yüzden bir kereye mahsus zorla kapatılıyor.
            // A genuinely fresh install has no such stored VP setting to migrate away from, and
            // DeepFilterNet is now free at Fn-press time once prewarmed, so a new user gets it by
            // default; an existing user hitting this migration for the first time keeps the
            // forced-off behavior above unchanged -- never silently switched to a mode they never
            // chose themselves.
            let migratedMode: AudioProcessingMode = isFreshInstall ? .deepFilterNet : .off
            audioProcessingMode = migratedMode
            defaults.set(migratedMode.rawValue, forKey: "audioProcessingMode")
            defaults.set(true, forKey: "voiceProcessingMigrationV1")
            owLog(isFreshInstall
                ? "[AppState] Voice processing migration: yeni kurulum, varsayılan DeepFilterNet"
                : "[AppState] Voice processing migration: gürültü engelleme kalıcı olarak kapatıldı (ölçülen gecikme ~1sn)")
        } else if let rawMode = defaults.string(forKey: "audioProcessingMode"),
                  let mode = AudioProcessingMode(rawValue: rawMode) {
            audioProcessingMode = mode
        } else {
            // Migration already ran once under the old Bool-only setting, but the new enum key
            // doesn't exist yet on this machine — translate the legacy value instead of
            // silently reintroducing VP's latency.
            let legacyVoiceProcessing = defaults.object(forKey: "noiseSuppressionEnabled") as? Bool ?? false
            audioProcessingMode = legacyVoiceProcessing ? .appleVoiceProcessing : .off
        }
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen3:8b"
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        targetSpeakerEnabled = defaults.object(forKey: "targetSpeakerEnabled") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        audioDuckingEnabled = defaults.object(forKey: "audioDuckingEnabled") as? Bool ?? true
        audioDuckingTargetVolume = defaults.object(forKey: "audioDuckingTargetVolume") as? Float ?? 0.20
        audioDuckingRestoreDuration = defaults.object(forKey: "audioDuckingRestoreDuration") as? Double ?? 1.5
        targetSpeakerProfileStore = profileStore
        self.targetSpeakerModel = targetSpeakerModel
        targetSpeakerFilter = TargetSpeakerFilter(model: targetSpeakerModel)
        self.targetSpeakerDiarization = targetSpeakerDiarization
        injectedTranscriptionService = transcriptionService
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
        syncAudioDuckerConfiguration()
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
        // Off the Fn-press path: DeepFilterNet's ~170ms model load happens once here instead of
        // on first use of that mode.
        let audioEngineForPrewarm = audioEngine
        DispatchQueue.global(qos: .utility).async {
            audioEngineForPrewarm?.prewarmDeepFilter()
        }
        transcriber = WhisperTranscriber()
        llmCleanup = LLMCleanup(model: ollamaModel)
        textInjector = TextInjector()
        flowBarController = FlowBarController(appState: self)
        syncFlowBarVisibility()

        loadTargetSpeakerProfile()
        startTargetSpeakerDiarizationPreparation()
        AudioDucker.shared.prewarmOutputDeviceCapability()

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
                let now = CACurrentMediaTime()
                let delayMs = (now - GlobalHotkey.lastFnPressUptime) * 1000
                owLog("[Perf] [HotkeyCallback] onPress callback triggered (+\(String(format: "%.2f", delayMs))ms from Fn press)")
                DispatchQueue.main.async {
                    let mainNow = CACurrentMediaTime()
                    let mainDelayMs = (mainNow - GlobalHotkey.lastFnPressUptime) * 1000
                    owLog("[Perf] [StartRecordingDispatch] startRecording scheduled on Main thread (+\(String(format: "%.2f", mainDelayMs))ms from Fn press)")
                    self?.startRecording()
                }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async { self?.stopRecordingWithTail() }
            },
            onSwapRequest: { [weak self] in
                DispatchQueue.main.async { self?.cancelRecordingForSwap() }
            },
            onSwapCommit: { [weak self] in
                DispatchQueue.main.async { self?.commitSwap() }
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
                if profile.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) {
                    targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                    owLog("[TargetSpeaker] loadTargetSpeakerProfile: loaded valid profile (embeddings=\(profile.embeddings.count), schema=\(profile.schemaVersion), model=\(profile.modelIdentifier))")
                } else {
                    targetSpeakerProfile = nil
                    targetSpeakerEnabled = false
                    // Same schema/model, only the audio pipeline changed -- give the user the
                    // specific reason instead of the generic model-version message.
                    let modelAndSchemaMatch = profile.schemaVersion == TargetSpeakerProfile.currentSchemaVersion
                        && profile.modelIdentifier == targetSpeakerModel.modelIdentifier
                    if modelAndSchemaMatch && profile.audioProcessingMode != audioProcessingMode {
                        targetSpeakerProfileStatus = "Ses işleme modu değişti — yeniden kayıt gerekli"
                        owLog("[TargetSpeaker] loadTargetSpeakerProfile: profile audio processing mode mismatch (profile=\(profile.audioProcessingMode), current=\(audioProcessingMode))")
                    } else {
                        targetSpeakerProfileStatus = "Model sürümü değişti — yeniden kayıt gerekli"
                        owLog("[TargetSpeaker] loadTargetSpeakerProfile: profile incompatible with model '\(targetSpeakerModel.modelIdentifier)'")
                    }
                }
            } else {
                targetSpeakerEnabled = false
                owLog("[TargetSpeaker] loadTargetSpeakerProfile: no saved profile found")
            }
        } catch {
            targetSpeakerProfile = nil
            hasStoredTargetSpeakerProfile = false
            targetSpeakerEnabled = false
            targetSpeakerProfileStatus = "Profil okunamadı — yeniden kayıt gerekli"
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] loadTargetSpeakerProfile error: \(error)")
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
        if let coherence = targetSpeakerProfileCoherence {
            owLog("[TargetSpeaker] Profile coherence refreshed: \(String(format: "%.3f", coherence))")
        }
    }

    /// Starts the optional overlap stack in the background. Normal dictation never awaits this
    /// task: if a download/preparation is still running, the target-speaker filter remains the
    /// conservative path for the current recording and a later recording can use diarization once
    /// preparation has completed.
    private func startTargetSpeakerDiarizationPreparation() {
        guard targetSpeakerEnabled,
              targetSpeakerProfile != nil,
              !targetSpeakerDiarizationReady,
              targetSpeakerDiarizationPreparationTask == nil else {
            owLog("[TargetSpeaker] startTargetSpeakerDiarizationPreparation skipped (enabled=\(targetSpeakerEnabled), profile=\(targetSpeakerProfile != nil), ready=\(targetSpeakerDiarizationReady), taskInFlight=\(targetSpeakerDiarizationPreparationTask != nil))")
            return
        }

        owLog("[TargetSpeaker] startTargetSpeakerDiarizationPreparation starting task...")
        let progressHandler: TargetSpeakerDiarizationProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, !self.targetSpeakerEnrollmentActive else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
                owLog("[TargetSpeaker] Diarization prep progress: phase=\(progress.phase), msg='\(progress.message)'")
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
        let tStart = CACurrentMediaTime()
        let elapsedFromFn = (tStart - GlobalHotkey.lastFnPressUptime) * 1000
        owLog("[Perf] [StartRecordingEnter] startRecording() entered (+\(String(format: "%.2f", elapsedFromFn))ms from Fn press)")

        if targetSpeakerEnrollmentActive {
            if targetSpeakerEnrollmentIsRecording {
                stopTargetSpeakerEnrollmentRecording()
            } else {
                startTargetSpeakerEnrollmentRecording()
            }
            return
        }
        // Cancel any pending tail-stop work item if a new recording starts immediately
        delayedStopWorkItem?.cancel()
        delayedStopWorkItem = nil

        // A previous session may still be transcribing. Only an already-active microphone
        // session blocks a new recording.
        guard recordingState != .recording else { return }
        clearFlowBarMessage()
        guard modelLoaded else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }

        if audioDuckingEnabled {
            AudioDucker.shared.duck()
        }

        // 1. Start microphone recording asynchronously off main thread FIRST — before any UI
        // work (flow bar appearance, NSWorkspace query) gets a chance to occupy the main thread
        // and delay this dispatch. Read everything the background block needs up front so the
        // dispatch itself has zero main-thread work between it and the guards above.
        let recordingInputDeviceUID = resolvedInputDeviceUID
        let processingMode = audioProcessingMode
        let audioEngineRef = audioEngine
        owLog("[OpenWhisper] Resolved recording input: \(recordingInputDeviceUID ?? "system default")")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didFallBackFromDeepFilter = audioEngineRef?.startRecording(
                deviceUID: recordingInputDeviceUID,
                audioProcessingMode: processingMode,
                levelCallback: { rawLevel in
                    let rms = max(rawLevel, 0.0001)
                    let dB = 20 * log10(rms)
                    let target = Float(min(max((dB + 46) / 46, 0.0), 1.0))
                    Task { @MainActor in
                        guard let self else { return }
                        self.audioLevel = target
                    }
                }
            ) ?? false

            let tAudioDone = CACurrentMediaTime()
            let audioElapsed = (tAudioDone - GlobalHotkey.lastFnPressUptime) * 1000
            owLog("[Perf] [AudioEngineStarted] Mic recording started (+\(String(format: "%.2f", audioElapsed))ms from Fn press)")

            // Non-blocking: this recording is already under way by the time this lands, so it
            // can never delay the Fn->audio path -- it only informs the user after the fact.
            if didFallBackFromDeepFilter {
                Task { @MainActor in
                    self?.showFlowBarMessage("Gürültü engelleme henüz hazır değildi, bu kayıt engelsiz işlendi")
                }
            }
        }

        // 2. Update recordingState so flow bar UI appears
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil

        // Save the currently focused app (instant NSWorkspace query)
        targetApp = NSWorkspace.shared.frontmostApplication
        owLog("[OpenWhisper] Target app: \(targetApp?.localizedName ?? "unknown")")

        // 3. Create session immediately with non-blocking initial context (AX details captured in background)
        nextTranscriptionID &+= 1
        let initialContext = PasteContext.initial(targetApp: targetApp)
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: targetApp,
            targetSpeakerEnabled: targetSpeakerEnabled,
            targetSpeakerProfile: targetSpeakerProfile,
            pasteContext: initialContext
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

        // 4. Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .recording else { return }
                self.recordingDuration += 0.25
                self.enqueueCompletedAudioSegments()
            }
        }

        // Dictation snapshot reset (instant if no active snapshot)
        DictationSnapshot.shared.handleNewDictationStarting()

        // 5. Perform non-essential background tasks asynchronously:
        // Async paste context capture off main thread
        let currentTargetApp = targetApp
        Task.detached(priority: .userInitiated) {
            let capturedContext = PasteContext.capture(targetApp: currentTargetApp)
            await MainActor.run { [weak session] in
                session?.pasteContext = capturedContext
            }
        }
    }

    /// Schedules stopRecording() after a short tail delay (default 0.40s / 400ms) so that speech spoken
    /// right as the hotkey/Fn key is released is not truncated from the audio buffer.
    func stopRecordingWithTail(delay: TimeInterval = 0.40) {
        guard recordingState == .recording else { return }
        delayedStopWorkItem?.cancel()
        owLog("[OpenWhisper] Hotkey released; keeping mic open for \(Int(delay * 1000))ms tail buffer...")
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        delayedStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stopRecording() {
        delayedStopWorkItem?.cancel()
        delayedStopWorkItem = nil

        AudioDucker.shared.restore()
        if targetSpeakerEnrollmentIsRecording {
            stopTargetSpeakerEnrollmentRecording()
            return
        }
        guard recordingState == .recording else { return }

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

        // If total audio duration is under 0.4 seconds (6400 samples at 16kHz),
        // skip entering the .transcribing state completely and return to idle.
        if session.queuedSampleCount < 6400 {
            owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s); skipping transcribing UI")
            session.isCancelled = true
            recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
            return
        }

        recordingState = .transcribing
        owLog("[OpenWhisper] Finishing recording; waiting for background batches...")
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
            owLog("[TargetSpeaker] Batch \(segmentNumber) filtering segment: samples=\(segment.samples.count), targetSpeakerEnabled=true, profileEmbeddings=\(session.targetSpeakerProfile?.embeddings.count ?? 0)")
            filtered = await targetSpeakerFilter.filter(
                samples: segment.samples,
                profile: session.targetSpeakerProfile,
                enabled: true,
                audioProcessingMode: audioProcessingMode
            )
            owLog("[TargetSpeaker] Batch \(segmentNumber) filter result: decision=\(filtered.decision), acceptedSamples=\(filtered.acceptedSampleCount)/\(segment.samples.count), hadVoice=\(filtered.hadVoiceActivity), wasFailClosed=\(filtered.wasFailClosed)")
            if filtered.wasFailClosed, let error = filtered.errorDescription {
                lastError = error
                targetSpeakerProfileStatus = "Filtre hata verdi — bu kayıt işlenmedi"
                session.hadFailClosedPassthrough = true
                owLog("[OpenWhisper] Target speaker filter failed closed: \(error)")
            }
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
        } else {
            owLog("[TargetSpeaker] Batch \(segmentNumber) targetSpeakerEnabled=false, bypassing filter")
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
            // --- Early rejection UI: show "Ses eşleşmedi" IMMEDIATELY ---
            // Don't wait for Whisper transcription; give the user instant feedback.
            // Transcription still continues in the background for clipboard salvage.
            if !session.earlyRejectionShown {
                session.earlyRejectionShown = true
                owLog("[TargetSpeaker] Batch \(segmentNumber) below threshold — processing for confirmation/salvage")
                if recordingState == .transcribing {
                    recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
                }
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
                        profile: profile,
                        audioProcessingMode: audioProcessingMode
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
        owLog("[TargetSpeaker] finishTranscription starting for session \(session.id): targetSpeakerEnabled=\(session.targetSpeakerEnabled), acceptedSamples=\(session.acceptedTargetSpeechSamples), hadSingleSpeakerUncertain=\(session.hadSingleSpeakerUncertain), hadFailClosed=\(session.hadFailClosedPassthrough), segmentTextsCount=\(session.segmentTexts.count), unmatchedSegmentTextsCount=\(session.unmatchedSegmentTexts.count)")

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
        if !session.hadFailClosedPassthrough &&
            (session.hadSingleSpeakerUncertain ||
             (session.hadDiarizationAttempt && session.segmentTexts.isEmpty) ||
             TargetSpeakerOutputGate.shouldSkipPostProcessing(
                 featureEnabled: session.targetSpeakerEnabled,
                 acceptedSampleCount: session.acceptedTargetSpeechSamples
             )) {
            let rawCandidateText: String = {
                let confirmationText = AudioSegmentation.joinTranscripts(session.confirmationTranscriptTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !confirmationText.isEmpty && !confirmationText.hasPrefix("[BLANK") && !confirmationText.hasPrefix("(BLANK") {
                    return confirmationText
                }
                let unmatchedText = AudioSegmentation.joinTranscripts(session.unmatchedSegmentTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !unmatchedText.isEmpty && !unmatchedText.hasPrefix("[BLANK") && !unmatchedText.hasPrefix("(BLANK") {
                    return unmatchedText
                }
                let allText = AudioSegmentation.joinTranscripts(session.allSegmentTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !allText.isEmpty && !allText.hasPrefix("[BLANK") && !allText.hasPrefix("(BLANK") {
                    return allText
                }
                return ""
            }()

            if !rawCandidateText.isEmpty {
                let candidateSamples = !session.ambiguousTargetSamples.isEmpty
                    ? session.ambiguousTargetSamples
                    : session.belowThresholdRejectedSamples
                let candidate = session.confirmationCandidate ?? TargetSpeakerConfirmationCandidate(
                    samples: candidateSamples,
                    windows: [],
                    internalCoherence: 0.5,
                    anchorProfileScore: 0.5,
                    separation: nil,
                    separationReason: "fallback candidate"
                )
                retainConfirmation(
                    candidate: candidate,
                    text: rawCandidateText,
                    pasteContext: session.pasteContext,
                    targetApp: session.targetApp
                )
                textInjector?.copyToClipboard(rawCandidateText)
                showTargetSpeakerAppendOffer(message: "")
                owLog("[OpenWhisper] Near-threshold candidate retained for 'Bu benim sesimdi' confirmation without showing error warning")
            } else {
                dismissFlowBarMessage()
            }
            return
        }
        guard session.queuedSampleCount >= 6400 else {
            owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)")
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
            var initialText = rawText

            let activePairs = CorrectionStore.shared.activePairs
            if !activePairs.isEmpty {
                let (corrected, applied) = CorrectionEngine.applyCorrections(to: initialText, pairs: activePairs)
                if !applied.isEmpty {
                    initialText = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                    for (wrong, right) in applied {
                        owLog("[Corrections] Applied learned correction: \(wrong) -> \(right)")
                    }
                }
            }

            self.lastTranscription = initialText

            if self.autoPasteEnabled {
                let targetApp = session.targetApp
                let pasteContext = session.pasteContext

                // Step 1: Paste raw/corrected text INSTANTLY (3-second path)
                self.textInjector?.pasteTextResult(
                    initialText,
                    targetApp: targetApp,
                    context: pasteContext
                ) { [weak self] outcome in
                    Task { @MainActor in
                        guard let self else { return }
                        switch outcome {
                        case .pastedVerified, .pastedUnverified:
                            self.swapPair = DictationPair(raw: rawText, cleaned: initialText)
                            self.swapTargetApp = targetApp
                            self.lastInjectedIsCleaned = false
                            self.lastInjectedText = initialText
                            self.hotkey?.setSwapAvailable(true)
                            DictationSnapshot.shared.capture(
                                pastedText: initialText,
                                targetApp: targetApp
                            )

                            self.dismissFlowBarMessage()

                            // Step 2: Run LLM Cleanup asynchronously in background (7-second path).
                            // Once Ollama finishes, replace the initially pasted text in-place.
                            if self.llmCleanupEnabled && self.ollamaAvailable {
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    let cleaned = await self.llmCleanup?.cleanup(text: rawText) ?? rawText
                                    let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

                                    guard !trimmedCleaned.isEmpty, trimmedCleaned != initialText else { return }
                                    owLog("[OpenWhisper] Async LLM cleanup complete: '\(trimmedCleaned)'. Replacing initial text...")

                                    self.textInjector?.replaceInjectedText(
                                        oldText: initialText,
                                        newText: trimmedCleaned,
                                        targetApp: targetApp
                                    ) { [weak self] in
                                        Task { @MainActor in
                                            guard let self else { return }
                                            self.swapPair = DictationPair(raw: rawText, cleaned: trimmedCleaned)
                                            self.lastTranscription = trimmedCleaned
                                            self.lastInjectedIsCleaned = true
                                            self.lastInjectedText = trimmedCleaned
                                            self.textInjector?.copyToClipboard(rawText)
                                            self.showFlowBarMessage("fixed", durationMs: 1000)
                                            owLog("[OpenWhisper] Async LLM replacement finished.")
                                        }
                                    }
                                }
                            }
                        case .clipboardOnly(let reason):
                            self.swapPair = nil
                            self.hotkey?.setSwapAvailable(false)
                            self.showFlowBarMessage(self.clipboardOnlyMessage(for: reason))
                        }
                    }
                }
            } else {
                self.textInjector?.copyToClipboard(initialText)
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

    func showFlowBarMessage(_ message: String, durationMs: Int = 1500) {
        flowBarMessageTask?.cancel()
        flowBarMessage = message
        syncFlowBarVisibility()
        flowBarMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled, let self else { return }
            self.flowBarMessage = nil
            self.syncFlowBarVisibility()
        }
    }

    /// Removes a transient flow-bar message without leaving the bar visible after a successful
    /// paste. Successful delivery is intentionally silent; only actionable outcomes remain.
    private func dismissFlowBarMessage() {
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        flowBarMessage = nil
        syncFlowBarVisibility()
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
        owLog("[TargetSpeaker] showTargetSpeakerAppendOffer: message='\(message)'")
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        flowBarMessage = message
        targetSpeakerAppendOfferActive = true
        syncFlowBarVisibility()

        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            owLog("[TargetSpeaker] Target speaker offer timed out after 8s")
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
        owLog("[TargetSpeaker] dismissTargetSpeakerAppendOffer")
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
            owLog("[TargetSpeaker] retainConfirmation rejected empty candidate or text")
            dismissTargetSpeakerAppendOffer()
            return
        }
        owLog("[TargetSpeaker] retainConfirmation stored candidate with \(candidate.samples.count) samples and text length \(text.count)")
        retainedConfirmationCandidate = candidate
        retainedConfirmationText = text
        retainedConfirmationPasteContext = pasteContext
        retainedConfirmationTargetApp = targetApp
    }

    /// Fired by the flow bar's "Bu benim sesimdi" tap. It delivers the retained transcript once
    /// and then explicitly appends the retained coherent candidate to the active profile.
    func confirmRetainedRecordingWasTargetSpeaker() {
        owLog("[TargetSpeaker] confirmRetainedRecordingWasTargetSpeaker called: offerActive=\(targetSpeakerAppendOfferActive), inFlight=\(isConfirmationInFlight), hasCandidate=\(retainedConfirmationCandidate != nil), textLength=\(retainedConfirmationText?.count ?? 0)")
        guard !isConfirmationInFlight,
              targetSpeakerAppendOfferActive,
              let candidate = retainedConfirmationCandidate,
              let textToPaste = retainedConfirmationText,
              let profile = targetSpeakerProfile else {
            owLog("[TargetSpeaker] confirmRetainedRecordingWasTargetSpeaker guard failed")
            return
        }

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
        owLog("[TargetSpeaker] Starting paste delivery and profile append for confirmed candidate...")
        textInjector?.pasteTextResult(
            textToPaste,
            targetApp: targetApp,
            context: pasteContext
        ) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.confirmationOperationID == operationID else { return }
                owLog("[TargetSpeaker] Confirmed candidate paste outcome: \(outcome)")
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
                    store: self.targetSpeakerProfileStore,
                    audioProcessingMode: self.audioProcessingMode
                )
                guard self.confirmationOperationID == operationID else { return }
                self.targetSpeakerProfile = receipt.appendedProfile
                self.refreshTargetSpeakerProfileCoherence()
                self.hasStoredTargetSpeakerProfile = true
                self.targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                self.lastConfirmedAppendReceipt = receipt
                self.confirmationAppendSucceeded = true
                self.confirmationAppendError = nil
                owLog("[TargetSpeaker] Confirmed candidate appended successfully to profile: new count=\(receipt.appendedProfile.embeddings.count)")
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

        owLog("[TargetSpeaker] finishConfirmationOperationIfReady: pasteOutcome=\(pasteOutcome), appendSucceeded=\(appendSucceeded), appendError=\(appendError ?? "none")")

        switch (pasteOutcome, appendSucceeded) {
        case (.pastedVerified, true), (.pastedUnverified, true):
            swapPair = nil
            hotkey?.setSwapAvailable(false)
            lastInjectedIsCleaned = true
            lastInjectedText = confirmationTextBeingDelivered
            showFlowBarMessage("Ses profiline eklendi")
        case (.clipboardOnly(_), true):
            showFlowBarMessage("Metin panoda, ses profiline eklendi")
        case (.pastedVerified, false), (.pastedUnverified, false):
            dismissFlowBarMessage()
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
        AudioDucker.shared.restore()
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
        owLog("[TargetSpeaker] beginTargetSpeakerEnrollment called")
        guard recordingState == .idle, !targetSpeakerEnrollmentIsProcessing else {
            owLog("[TargetSpeaker] beginTargetSpeakerEnrollment skipped (state=\(recordingState), processing=\(targetSpeakerEnrollmentIsProcessing))")
            return
        }
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
        owLog("[TargetSpeaker] startTargetSpeakerEnrollmentRecording step=\(targetSpeakerEnrollmentStep + 1)/\(TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount)")
        guard recordingState == .idle,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              let audioEngine else {
            owLog("[TargetSpeaker] startTargetSpeakerEnrollmentRecording skipped (state=\(recordingState), processing=\(targetSpeakerEnrollmentIsProcessing), step=\(targetSpeakerEnrollmentStep))")
            return
        }

        clearFlowBarMessage()

        if audioDuckingEnabled {
            AudioDucker.shared.duck()
        }

        targetSpeakerEnrollmentIsRecording = true
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        lastError = nil
        audioEngine.startRecording(
            deviceUID: resolvedInputDeviceUID,
            audioProcessingMode: audioProcessingMode,
            levelCallback: { [weak self] rawLevel in
                let rms = max(rawLevel, 0.0001)
                let dB = 20 * log10(rms)
                let target = Float(min(max((dB + 46) / 46, 0.0), 1.0))
                Task { @MainActor in
                    guard let self else { return }
                    self.audioLevel = target
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
                    owLog("[TargetSpeaker] Enrollment recording step \(self.targetSpeakerEnrollmentStep + 1) reached max duration 30s")
                    self.stopTargetSpeakerEnrollmentRecording()
                }
            }
        }
    }

    func stopTargetSpeakerEnrollmentRecording() {
        owLog("[TargetSpeaker] stopTargetSpeakerEnrollmentRecording called")
        AudioDucker.shared.restore()
        guard targetSpeakerEnrollmentIsRecording else { return }
        let samples = teardownTargetSpeakerEnrollmentRecording()

        guard !samples.isEmpty else {
            targetSpeakerEnrollmentStatus = "Kayıt alınamadı; tekrar deneyin."
            owLog("[TargetSpeaker] Enrollment recording returned 0 samples")
            return
        }

        owLog("[TargetSpeaker] Enrollment recording step \(targetSpeakerEnrollmentStep + 1) stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")
        processTargetSpeakerEnrollmentSamples(samples)
    }

    /// Shared enrollment boundary used by the audio path and deterministic state tests.
    func processTargetSpeakerEnrollmentSamples(_ samples: [Float]) {
        owLog("[TargetSpeaker] processTargetSpeakerEnrollmentSamples: step=\(targetSpeakerEnrollmentStep + 1), samples=\(samples.count)")
        guard targetSpeakerEnrollmentActive,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              !samples.isEmpty else {
            owLog("[TargetSpeaker] processTargetSpeakerEnrollmentSamples skipped (active=\(targetSpeakerEnrollmentActive), processing=\(targetSpeakerEnrollmentIsProcessing), step=\(targetSpeakerEnrollmentStep))")
            return
        }

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
                owLog("[TargetSpeaker] Validating enrollment sample \(sampleIndex + 1)...")
                let result = try await self.targetSpeakerFilter.validateEnrollmentSample(
                    recording,
                    progressHandler: progressHandler
                )
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                guard result.isValid else {
                    self.targetSpeakerEnrollmentStatus = "Bu kayıt en az 10 saniye net konuşma içermiyor veya çok kırpılmış; aynı pozisyonda yeniden kaydedin."
                    owLog("[TargetSpeaker] Enrollment sample \(sampleIndex + 1) invalid: voicedDuration=\(result.voicedDuration)s, clippedRatio=\(result.clippedSampleRatio)")
                    return
                }

                guard sampleIndex == self.targetSpeakerEnrollmentRecordings.count else {
                    self.targetSpeakerEnrollmentStatus = "Kayıt sırası değişti; lütfen yeniden başlayın."
                    owLog("[TargetSpeaker] Sample index mismatch: sampleIndex=\(sampleIndex), count=\(self.targetSpeakerEnrollmentRecordings.count)")
                    return
                }
                self.targetSpeakerEnrollmentRecordings.append(recording)
                owLog("[TargetSpeaker] Enrollment sample \(sampleIndex + 1) validated and stored (\(recording.count) samples)")

                if self.targetSpeakerEnrollmentRecordings.count < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount {
                    self.targetSpeakerEnrollmentStep += 1
                    self.targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[1]
                    self.targetSpeakerEnrollmentStatus = "İlk kayıt tamamlandı. Duruşunu değiştir ve ikinci kaydı başlat."
                    owLog("[TargetSpeaker] First enrollment sample completed. Prompting for second sample.")
                    return
                }

                self.targetSpeakerEnrollmentStep = TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount
                self.targetSpeakerEnrollmentStatus = "İki kayıt doğrulandı; profil çıkarılıyor…"
                owLog("[TargetSpeaker] Both enrollment samples validated. Creating profile...")
                do {
                    let profile = try await self.targetSpeakerFilter.createProfile(
                        from: self.targetSpeakerEnrollmentRecordings,
                        store: self.targetSpeakerProfileStore,
                        progressHandler: progressHandler,
                        audioProcessingMode: self.audioProcessingMode
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
                    owLog("[TargetSpeaker] Profile created and saved successfully! Total embeddings=\(profile.embeddings.count)")
                } catch {
                    guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
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
                    owLog("[TargetSpeaker] Profile creation failed: \(error.localizedDescription) (failedIndex=\(failedIndex))")
                }
            } catch {
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerEnrollmentStatus = error.localizedDescription
                owLog("[TargetSpeaker] Enrollment sample validation failed with error: \(error)")
            }
        }
    }

    func cancelTargetSpeakerEnrollment() {
        owLog("[TargetSpeaker] cancelTargetSpeakerEnrollment called")
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
        owLog("[TargetSpeaker] deleteTargetSpeakerProfile called")
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
            owLog("[TargetSpeaker] Target speaker profile deleted")
        } catch {
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] Delete target speaker profile failed: \(error)")
        }
    }

    func undoLastConfirmedTargetSpeakerAppend() {
        owLog("[TargetSpeaker] undoLastConfirmedTargetSpeakerAppend called")
        guard let receipt = lastConfirmedAppendReceipt else {
            owLog("[TargetSpeaker] undoLastConfirmedTargetSpeakerAppend: no receipt available")
            return
        }
        do {
            try targetSpeakerFilter.undoConfirmedAppend(receipt, store: targetSpeakerProfileStore)
            targetSpeakerProfile = receipt.previousProfile
            refreshTargetSpeakerProfileCoherence()
            hasStoredTargetSpeakerProfile = true
            targetSpeakerProfileStatus = "Son ekleme geri alındı"
            lastConfirmedAppendReceipt = nil
            lastError = nil
            owLog("[TargetSpeaker] Last confirmed append undone successfully; restored embeddings count=\(receipt.previousProfile.embeddings.count)")
        } catch {
            lastError = error.localizedDescription
            targetSpeakerProfileStatus = error.localizedDescription
            owLog("[TargetSpeaker] Undo last confirmed append failed: \(error)")
        }
    }

    func replaceTargetSpeakerProfile() {
        owLog("[TargetSpeaker] replaceTargetSpeakerProfile called")
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
        // If the previously selected device is no longer present, automatic mode resolves the
        // next recording to a connected headset or the built-in Mac microphone.
        if let uid = inputDeviceUID, !availableInputDevices.contains(where: { $0.uid == uid }) {
            inputDeviceUID = nil
        }
    }

    /// Automatic mode prefers a connected headset and falls back to the built-in Mac
    /// microphone. An explicit picker selection still wins, and a temporarily unavailable
    /// explicit device falls back to the same automatic policy for the next recording.
    var resolvedInputDeviceUID: String? {
        guard let inputDeviceUID else { return nil }
        let devices = AudioEngine.availableInputDevices()
        if devices.contains(where: { $0.uid == inputDeviceUID }) {
            return inputDeviceUID
        }
        return AudioEngine.automaticInputDeviceUID()
    }

    /// Returns true when the resolved dictation input is a Bluetooth device.
    var resolvedInputIsBluetooth: Bool {
        guard let uid = resolvedInputDeviceUID else { return false }
        return AudioEngine.availableInputDevices().first(where: { $0.uid == uid })?.isBluetooth ?? false
    }

    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
    }
}
