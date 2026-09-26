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
    let startedAt = Date()
    let targetApp: NSRunningApplication?
    var pasteContext: PasteContext
    let stream: AsyncStream<CompletedAudioSegment>
    let continuation: AsyncStream<CompletedAudioSegment>.Continuation
    let targetSpeakerEnabled: Bool
    let targetSpeakerProfile: TargetSpeakerProfile?
    /// Started by voice ("Jarvis", Vocal Shortcuts, openwhisper://start) rather than Fn:
    /// the user is giving a command, so Spotify intents are read less strictly.
    var isVoiceCommand = false
    /// How the recording was started; upgraded to `.fnSpace` when Space locks a Fn hold.
    var trigger: RecordingTrigger = .fnHold

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
    /// The "Jarvis" that started this session already matched the user's voice. A recording
    /// with one coherent speaker is then the user, even if its absolute score is borderline.
    var wakeSpeakerVerified = false
    var hadDiarizationAttempt = false
    var hadDiarizationTargetSpeech = false
    var hadDiarizationFailure = false
    var hadDiarizedOverlap = false
    var queuedSampleCount = 0
    var nextSegmentNumber = 0
    var isCancelled = false
    var historySaveFailed = false
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

/// A user-installed STT provider (manifest found under
/// `~/Library/Application Support/OpenWhisper/STTProviders`) that has not yet been explicitly
/// approved to run. Carries the resolved paths so Settings can show the user exactly what they'd
/// be authorizing before they approve it. `manifestPath` is always present -- it's just the
/// location the manifest was found at. `pythonPath`/`bridgePath` are nil when the security checks
/// in `ExternalSTTProvider.resolveRuntime()` rejected the manifest (bridge escapes its directory,
/// no allowlisted interpreter matched, etc.); such a provider still shows up here as rejected
/// rather than silently disappearing from Settings.
struct PendingProviderApproval: Identifiable, Sendable {
    let id: String
    let displayName: String
    let manifestPath: String
    let pythonPath: String?
    let bridgePath: String?
}

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    private let recordingHistoryStore = RecordingHistoryStore()
    var savedRecordings: [SavedRecording] = []
    var replayingRecordingID: UUID?
    var replayStatus: String?
    var systemAudioEnabled = false {
        didSet {
            syncFlowBarVisibility()
            updateWakeWordListener()
        }
    }
    var systemAudioIsRecording = false {
        didSet {
            guard oldValue != systemAudioIsRecording else { return }
            syncFlowBarVisibility()
        }
    }
    var systemAudioIsTranscribing = false
    var systemAudioStatus = "Kapalı"

    // MARK: - Recording State

    enum RecordingState: Sendable, Equatable {
        case idle, recording, transcribing
    }

    var recordingState: RecordingState = .idle {
        didSet {
            guard oldValue != recordingState else { return }
            syncFlowBarVisibility()
            updateWakeWordListener()
        }
    }

    // MARK: - Settings (persisted via UserDefaults)

    /// Selected transcription-provider ID. The persisted key remains `whisperModel` for
    /// backwards compatibility with existing installations.
    var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "whisperModel") }
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
    /// Jarvis answers voice commands out loud (`JarvisVoice`, local OmniVoice model).
    var voiceRepliesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceRepliesEnabled, forKey: "voiceRepliesEnabled")
            if voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }
        }
    }
    @ObservationIgnored private var jarvisReply = JarvisReply()
    enum JarvisActivity: Sendable, Equatable {
        case none, thinking, speaking
    }
    /// What Jarvis is doing after a command: the flow bar shows "thinking" / "speaking"
    /// instead of "transcribing".
    var jarvisActivity: JarvisActivity = .none {
        didSet {
            guard oldValue != jarvisActivity else { return }
            syncFlowBarVisibility()
        }
    }
    var laughterToRandomEnabled: Bool {
        didSet { UserDefaults.standard.set(laughterToRandomEnabled, forKey: "laughterToRandomEnabled") }
    }
    var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
            llmCleanup = LLMCleanup(model: ollamaModel)
            Task { [weak self] in
                guard let self else { return }
                await self.refreshOllamaStatus()
            }
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
                prepareWakeSpeakerModel()
            }
        }
    }
    /// Which audio "Yalnızca Benim Sesim" guards: the "Jarvis" wake word, dictation, or both.
    var targetSpeakerScope = TargetSpeakerScope(
        rawValue: UserDefaults.standard.string(forKey: TargetSpeakerScope.defaultsKey) ?? ""
    ) ?? TargetSpeakerScope.defaultValue {
        didSet {
            owLog("[TargetSpeaker] targetSpeakerScope changed to \(targetSpeakerScope.rawValue)")
            UserDefaults.standard.set(targetSpeakerScope.rawValue, forKey: TargetSpeakerScope.defaultsKey)
            startTargetSpeakerDiarizationPreparation()
            prepareWakeSpeakerModel()
        }
    }
    /// Dictation goes through the target-speaker filter.
    var targetSpeakerFiltersTranscription: Bool {
        targetSpeakerEnabled && targetSpeakerScope.coversTranscription
    }
    /// "Jarvis" wakes only for the enrolled voice.
    private var targetSpeakerGuardsWakeWord: Bool {
        targetSpeakerEnabled && targetSpeakerScope.coversWakeWord && targetSpeakerProfile != nil
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
        }
    }

    // MARK: - Runtime State

    var availableInputDevices: [AudioInputDevice] = []
    var systemDefaultInputIsBluetooth: Bool = false

    var builtInInputDevice: AudioInputDevice? {
        availableInputDevices.first(where: { $0.isBuiltIn })
    }

    var externalHeadsetDevice: AudioInputDevice? {
        AudioEngine.connectedExternalHeadsetDevice()
    }

    var audioLevel: Float = 0.0
    /// True while a hands-free recording (⌘⌥⌃D, Fn+Space, openwhisper://) is running; the
    /// FlowBar shows a stop button then, since there is no held key to release.
    var handsFreeActive = false {
        // Re-measure the panel: the stop button changes its width.
        didSet { if oldValue != handsFreeActive { syncFlowBarVisibility() } }
    }
    var recordingDuration: TimeInterval = 0.0
    var ollamaAvailable: Bool = false
    /// Availability of the selected cleanup engine.
    var cleanupAvailable: Bool = false
    var modelLoaded: Bool = false {
        didSet { updateWakeWordListener() }
    }
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
    var targetSpeakerEnrollmentIsRecording = false {
        didSet { updateWakeWordListener() }
    }
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

    /// On-demand voice sample capture. Separate from enrollment: enrollment builds a profile
    /// from exactly two recordings, while this appends a single extra sample to an existing
    /// profile at any time — so a speaking condition that gets misrecognised (speaking quietly,
    /// a louder person nearby, a different posture) can be taught the moment it happens instead
    /// of only through the 8-second offer that follows a rejected dictation.
    var targetSpeakerSampleIsRecording = false
    var targetSpeakerSampleIsProcessing = false
    var targetSpeakerSampleStatus: String = ""

    var canCaptureTargetSpeakerSample: Bool {
        hasStoredTargetSpeakerProfile
            && !targetSpeakerEnrollmentActive
            && !targetSpeakerEnrollmentIsProcessing
            && !targetSpeakerSampleIsProcessing
    }
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
    private let transcriptionModelRegistry = TranscriptionModelRegistry()
    private var llmCleanup: LLMCleanup?
    /// Bumped for every transcript: a background correction only acts if no newer
    /// transcript came in meanwhile.
    private var correctionGeneration: UInt64 = 0
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
    /// Menu bar switch for the own "Jarvis" listener.
    var wakeWordEnabled = UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled")
            updateWakeWordListener()
        }
    }
    private(set) var wakeWordListening = false
    private(set) var wakeWordStatus = "Kapalı"
    @ObservationIgnored private var wakeWordListener: WakeWordListener?
    @ObservationIgnored private var wakeCandidateVerifying = false
    /// Bumped per weak direct detection so a late verdict never discards a newer session.
    @ObservationIgnored private var wakeConfirmationID = 0
    /// The wake speaker check finished before the session it belongs to was created.
    @ObservationIgnored private var pendingWakeSpeakerVerified = false
    @ObservationIgnored private var mediaActivityMonitor: SystemMediaActivityMonitor?
    @ObservationIgnored private var mediaPlaying = false
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let recordingMedia = RecordingMediaController.shared
    /// Set by a URL start just before it reaches `startRecording()`, consumed there.
    @ObservationIgnored private var armVoiceAutoStopForNextRecording = false
    /// Present only for voice-triggered sessions; ends them after the speaker goes quiet.
    @ObservationIgnored private var voiceEndpointDetector: VoiceEndpointDetector?
    @ObservationIgnored private var lastVoiceEndpointTrace: TimeInterval = 0
    /// Wake-word sessions with an enrolled voice: ends them when the user stops, even while
    /// someone else keeps talking. See `OwnVoiceStopGate`.
    @ObservationIgnored private var ownVoiceStopGate: OwnVoiceStopGate?
    @ObservationIgnored private var ownVoiceCheckInFlight = false
    @ObservationIgnored private var lastOwnVoiceCheck: TimeInterval = 0
    private var systemAudioCapture: SystemAudioCapture?
    private var systemAudioGeneration: UInt64 = 0
    private var systemAudioTranscriptionTail: Task<Void, Never>?
    private var recordingPreviewTask: Task<Void, Never>?

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
    /// AX baseline for the latest injected span, retained so cleanup/swap can update a
    /// background target without reactivating it.
    private var swapPasteContext: PasteContext?

    // MARK: - Computed

    var menuBarIcon: String {
        switch recordingState {
        case .idle: systemAudioEnabled ? "speaker.wave.2.fill" : "mic.fill"
        case .recording: "waveform"
        case .transcribing: "waveform.path.ecg"
        }
    }

    var menuBarIconColor: Color {
        switch recordingState {
        case .idle: systemAudioIsRecording ? .red : .white
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
        transcriptionModel = defaults.string(forKey: "whisperModel") ?? TranscriptionModelRegistry.defaultModelID
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
        laughterToRandomEnabled = defaults.object(forKey: "laughterToRandomEnabled") as? Bool ?? false
        voiceRepliesEnabled = defaults.object(forKey: "voiceRepliesEnabled") as? Bool ?? true
        let savedModel = defaults.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
        // Models dropped from the picker (the ByT5 normalizer, llama3.2:3b) fall back to the default
        // instead of leaving a selection Settings can't show.
        let isSupported = LLMCleanup.supportedModels.contains { $0.tag == savedModel }
        ollamaModel = isSupported ? savedModel : LLMCleanup.defaultModel
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        targetSpeakerEnabled = defaults.object(forKey: "targetSpeakerEnabled") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        audioDuckingEnabled = defaults.object(forKey: "audioDuckingEnabled") as? Bool ?? true
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
        savedRecordings = await recordingHistoryStore.items()
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
        llmCleanup = LLMCleanup(model: ollamaModel)
        textInjector = TextInjector()
        flowBarController = FlowBarController(appState: self)
        syncFlowBarVisibility()

        loadTargetSpeakerProfile()
        startTargetSpeakerDiarizationPreparation()
        // The voice model takes ~15 s to load; do it now rather than on the first reply.
        if voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }

        // Request mic permission
        microphoneGranted = await audioEngine?.requestPermission() ?? false
        owLog("[OpenWhisper] Microphone permission: \(microphoneGranted)")

        // Enumerate input devices for the picker + BT detection
        refreshInputDevices()
        owLog("[OpenWhisper] Input devices: \(availableInputDevices.count), default-is-BT: \(systemDefaultInputIsBluetooth)")

        // Check accessibility
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: true)
        owLog("[OpenWhisper] Accessibility: \(accessibilityGranted)")

        // Manual correction review (Option+Shift+C) feedback: DictationSnapshot deliberately
        // has no AppState/AppKit dependency, so it reports outcomes through a plain closure
        // instead. Duration varies by message — the "nothing happened" messages are shorter
        // than the ones confirming something was actually learned or explicitly rejected.
        DictationSnapshot.shared.onManualReviewResult = { [weak self] message in
            let shortMessages: Set<String> = [
                "karşılaştırılacak dikte yok", "değişiklik yok", "uygun düzeltme bulunamadı", "metin okunamadı"
            ]
            let durationMs = shortMessages.contains(message) ? 2000 : 2500
            self?.showFlowBarMessage(message, durationMs: durationMs)
        }

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
        hotkey?.onVoiceSessionRequest = { [weak self] in
            Task { @MainActor in
                owLog("[OpenWhisper] Voice session requested (Vocal Shortcut)")
                self?.startVoiceSession()
            }
        }
        hotkey?.onHandsFreeChange = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                self.handsFreeActive = active
                // Fn hold → Space: same recording, now hands-free.
                if active, let trigger = self.hotkey?.trigger, self.recordingState == .recording {
                    self.activeTranscriptionSession?.trigger = trigger
                }
            }
        }
        hotkey?.register()
        owLog("[OpenWhisper] Hotkey registered (Fn/Globe)")

        // Load Whisper model
        owLog("[OpenWhisper] Loading model: \(transcriptionModel)...")
        await loadModel()
        owLog("[OpenWhisper] Model loaded: \(modelLoaded)")

        setupWakeWordListener()

        // Check Ollama availability
        await refreshOllamaStatus()
        owLog("[OpenWhisper] Ollama available: \(ollamaAvailable)")
        owLog("[OpenWhisper] Selected cleanup available: \(cleanupAvailable)")

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
        guard targetSpeakerFiltersTranscription,
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

    func downloadedTranscriptionModelNames() -> [String] {
        transcriptionModelRegistry.providers.values
            .filter(\.isDownloaded)
            .map { $0.descriptor.id }
            .sorted()
    }

    func transcriptionModelCatalog() -> [(name: String, label: String)] {
        transcriptionModelRegistry.availableProviders.map {
            (name: $0.descriptor.id, label: $0.descriptor.displayName)
        }
    }

    /// User-installed providers (manifest discovered from the user-writable STTProviders
    /// directory) that are not yet approved to run. `.bundled` providers never appear here --
    /// they're trusted like the rest of the app and have no gate to clear. See
    /// `ExternalSTTProvider`'s approval gate for why this exists.
    func pendingProviderApprovals() -> [PendingProviderApproval] {
        transcriptionModelRegistry.providers.values
            .compactMap { $0 as? ExternalSTTProvider }
            .filter { $0.trust == .userInstalled && !$0.isApproved() }
            .map { provider -> PendingProviderApproval in
                // manifestPath is always present; pythonPath/bridgePath are nil when
                // resolveRuntime() rejected the provider (e.g. bridge escapes the manifest
                // directory, or no allowlisted interpreter matched). We deliberately do NOT drop
                // those providers here -- the most suspicious manifest is exactly the one that
                // failed resolution, and it must still show up in Settings instead of vanishing
                // with only a log line as the trace.
                let paths = provider.approvalDisplayPaths
                return PendingProviderApproval(
                    id: provider.descriptor.id,
                    displayName: provider.descriptor.displayName,
                    manifestPath: paths.manifestPath,
                    pythonPath: paths.pythonPath,
                    bridgePath: paths.bridgePath
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Records the user's explicit approval, fingerprinted to the provider's current
    /// manifest+bridge bytes so a later file change silently revokes it again.
    func approveProvider(id: String) {
        guard let provider = transcriptionModelRegistry.provider(for: id) as? ExternalSTTProvider else { return }
        provider.approve()
    }

    func revokeProviderApproval(id: String) {
        guard let provider = transcriptionModelRegistry.provider(for: id) as? ExternalSTTProvider else { return }
        provider.revokeApproval()
    }

    /// User-installed providers currently approved to run, so Settings can offer a revoke action.
    func approvedUserInstalledProviderIDs() -> [String] {
        transcriptionModelRegistry.providers.values
            .compactMap { $0 as? ExternalSTTProvider }
            .filter { $0.trust == .userInstalled && $0.isApproved() }
            .map(\.descriptor.id)
            .sorted()
    }

    func loadModel() async {
        modelLoaded = false
        modelLoading = true
        modelLoadProgress = 0
        guard let provider = transcriptionModelRegistry.provider(for: transcriptionModel) else {
            modelLoading = false
            lastError = "Seçili konuşma modeli bulunamadı: \(transcriptionModel)"
            owLog("[OpenWhisper] Model provider not found: \(transcriptionModel)")
            return
        }
        modelIsDownloading = !provider.isDownloaded
        owLog("[OpenWhisper] Loading model: \(provider.descriptor.id) (download needed: \(modelIsDownloading))...")
        do {
            try await provider.loadModel { [weak self] progress in
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

    private var activeTranscriptionService: WhisperTranscriptionService? {
        if let injectedTranscriptionService {
            return injectedTranscriptionService
        }
        return transcriptionModelRegistry.provider(for: transcriptionModel)
    }

    // MARK: - Recording Flow

    /// Listens to the mixed Mac output. The mic/Fn recording path remains separate.
    func startSystemAudioListening() {
        guard !systemAudioEnabled else { return }
        recordingPreviewTask?.cancel()
        guard modelLoaded else {
            systemAudioStatus = "Önce konuşma modeli yüklensin."
            return
        }
        systemAudioGeneration &+= 1
        let generation = systemAudioGeneration
        let capture = SystemAudioCapture()
        systemAudioCapture = capture
        systemAudioEnabled = true
        systemAudioStatus = "Bilgisayar sesi açılıyor…"
        capture.onClip = { [weak self] samples in
            Task { @MainActor [weak self] in self?.enqueueSystemAudioClip(samples) }
        }
        capture.onRecordingChange = { [weak self] active in
            Task { @MainActor [weak self] in
                guard let self, self.systemAudioEnabled else { return }
                self.systemAudioIsRecording = active
                self.systemAudioStatus = active ? "Bilgisayar sesi kaydediliyor" : "Yeni ses bekleniyor"
            }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.systemAudioGeneration == generation else { return }
                self.lastError = message
                self.stopSystemAudioListening()
                self.systemAudioStatus = message
            }
        }
        Task { @MainActor [weak self] in
            do {
                try await capture.start()
                guard let self, self.systemAudioGeneration == generation, self.systemAudioEnabled else {
                    await capture.stop()
                    return
                }
                self.systemAudioStatus = "Yeni ses bekleniyor"
            } catch {
                guard let self, self.systemAudioGeneration == generation else { return }
                let message = "Bilgisayar sesi açılamadı: \(error.localizedDescription)"
                self.lastError = message
                self.stopSystemAudioListening()
                self.systemAudioStatus = message
            }
        }
    }

    func stopSystemAudioListening() {
        guard systemAudioEnabled || systemAudioCapture != nil else { return }
        systemAudioGeneration &+= 1
        systemAudioEnabled = false
        systemAudioIsRecording = false
        systemAudioStatus = "Kapalı"
        let capture = systemAudioCapture
        systemAudioCapture = nil
        Task { await capture?.stop() }
    }

    private func enqueueSystemAudioClip(_ samples: [Float]) {
        guard samples.count >= 6_400 else { return }
        let previous = systemAudioTranscriptionTail
        systemAudioTranscriptionTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.transcribeSystemAudioClip(samples)
        }
    }

    private func transcribeSystemAudioClip(_ samples: [Float]) async {
        systemAudioIsTranscribing = true
        defer { systemAudioIsTranscribing = false }
        systemAudioStatus = "Bilgisayar sesi yazıya dökülüyor…"
        nextTranscriptionID &+= 1
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: nil,
            targetSpeakerEnabled: false,
            targetSpeakerProfile: nil,
            pasteContext: PasteContext.initial(targetApp: nil)
        )
        var saveFailed = false
        for part in AudioSegmentation.makeSegments(from: samples) {
            let segment = CompletedAudioSegment(samples: Array(part.samples), overlapSampleCount: part.overlapSampleCount)
            session.queuedSampleCount += segment.samples.count - segment.overlapSampleCount
            do {
                try await recordingHistoryStore.append(segment, sessionID: session.id, startedAt: session.startedAt)
            } catch {
                saveFailed = true
                owLog("[SystemAudio] History save failed: \(error)")
            }
            await transcribeStreamingSegment(segment, session: session)
        }
        let recordingID = await recordingHistoryStore.activeRecordingID(sessionID: session.id)
        do {
            savedRecordings = try await recordingHistoryStore.finish(
                sessionID: session.id,
                keep: !saveFailed,
                previewText: AudioSegmentation.joinTranscripts(session.segmentTexts),
                whisperSegments: session.allSegmentTexts.count
            )
        } catch {
            owLog("[SystemAudio] History finish failed: \(error)")
            lastError = "Bilgisayar sesi geçmişe kaydedilemedi: \(error.localizedDescription)"
        }
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Started: \(session.startedAt.formatted(date: .numeric, time: .standard))",
                "Source: system audio",
                String(format: "Duration: %.1f s", Double(samples.count) / 16_000),
                "Whisper segments: \(session.allSegmentTexts)",
            ] + (savedRecordings.first { $0.id == traceID }?.stats?.logLines ?? []))
        }
        await VoiceTrace.$current.withValue(traceID) {
            await finishSystemAudioClip(session)
        }
    }

    private func finishSystemAudioClip(_ session: RecordingTranscriptionSession) async {
        var output = AudioSegmentation.joinTranscripts(session.segmentTexts)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, !output.hasPrefix("[BLANK"), !output.hasPrefix("(BLANK") else {
            owLog("[Result] System audio: no text")
            systemAudioStatus = systemAudioEnabled ? "Yeni ses bekleniyor" : "Metin çıkarılamadı"
            return
        }
        output = CorrectionEngine.applyCorrections(to: output, pairs: CorrectionStore.shared.activePairs).0
        output = PhoneticGlossaryCorrector.correct(output).0
        if laughterToRandomEnabled {
            output = LaughterRandomizer.transform(output).text
        } else if llmCleanupEnabled && cleanupAvailable {
            output = await llmCleanup?.cleanup(text: output) ?? output
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        lastTranscription = output
        textInjector?.copyToClipboard(output)
        systemAudioStatus = systemAudioEnabled
            ? "Metin panoya kopyalandı · yeni ses bekleniyor"
            : "Metin panoya kopyalandı"
        owLog("[SystemAudio] Transcript copied to clipboard")
        owLog("[Result] System audio copied to clipboard: '\(output)'")
    }

    func startRecording() {
        recordingPreviewTask?.cancel()
        let tStart = CACurrentMediaTime()
        let elapsedFromFn = (tStart - GlobalHotkey.lastFnPressUptime) * 1000
        owLog("[Perf] [StartRecordingEnter] startRecording() entered (+\(String(format: "%.2f", elapsedFromFn))ms from Fn press)")
        // A new command cuts Jarvis off, and his voice must not end up in the recording.
        JarvisVoice.shared.stop()

        if targetSpeakerEnrollmentActive {
            if targetSpeakerEnrollmentIsRecording {
                stopTargetSpeakerEnrollmentRecording()
            } else {
                startTargetSpeakerEnrollmentRecording()
            }
            return
        }
        // Cancel any pending tail-stop work item and finish previous recording if a new recording starts immediately
        if delayedStopWorkItem != nil {
            delayedStopWorkItem?.cancel()
            delayedStopWorkItem = nil
            stopRecording()
        }

        let armVoiceAutoStop = armVoiceAutoStopForNextRecording
        armVoiceAutoStopForNextRecording = false

        // A previous session may still be transcribing. Only an already-active microphone
        // session blocks a new recording.
        guard recordingState != .recording else { return }
        clearFlowBarMessage()
        guard modelLoaded else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }
        let sessionStart = CACurrentMediaTime()
        voiceEndpointDetector = armVoiceAutoStop
            ? VoiceEndpointDetector(
                startTime: sessionStart,
                config: resolvedInputIsBluetooth ? .closeTalk : .init(),
                ignoreUntil: mediaPlaying ? sessionStart + 0.8 : nil
            )
            : nil
        ownVoiceStopGate = armVoiceAutoStop && hotkey?.trigger == .wakeWord
            && targetSpeakerEnabled && targetSpeakerProfile != nil
            ? OwnVoiceStopGate(threshold: OwnVoiceStopGate.defaultThreshold)
            : nil
        ownVoiceCheckInFlight = false
        lastOwnVoiceCheck = sessionStart
        if ownVoiceStopGate != nil { owLog("[OwnVoiceStop] Armed for wake-word session") }

        if audioDuckingEnabled || armVoiceAutoStop {
            recordingMedia.begin()
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
                    let target = AudioSignalProcessor.displayLevel(forRawRMS: rawLevel)
                    // Stamped here, on the audio thread, so main-thread stalls can't distort
                    // the voice auto-stop's silence timing.
                    let levelTime = CACurrentMediaTime()
                    Task { @MainActor in
                        guard let self else { return }
                        self.audioLevel = target
                        self.feedVoiceEndpoint(rawRMS: rawLevel, at: levelTime)
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
            targetSpeakerEnabled: targetSpeakerFiltersTranscription,
            targetSpeakerProfile: targetSpeakerProfile,
            pasteContext: initialContext
        )
        session.isVoiceCommand = armVoiceAutoStop
        session.trigger = hotkey?.trigger ?? .fnHold
        session.wakeSpeakerVerified = session.trigger == .wakeWord && pendingWakeSpeakerVerified
        pendingWakeSpeakerVerified = false
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
                if !session.historySaveFailed {
                    do {
                        try await self.recordingHistoryStore.append(segment, sessionID: session.id, startedAt: session.startedAt)
                    } catch {
                        session.historySaveFailed = true
                        owLog("[RecordingHistory] Save failed: \(error)")
                        self.lastError = "Ses geçmişi kaydedilemedi: \(error.localizedDescription)"
                    }
                }
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
                self.checkOwnVoiceEndpoint()
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
    /// right as the hotkey/Fn key is released is not truncated from the audio buffer. Visually,
    /// the UI transitions to `.transcribing` immediately on key release so the user feels an instant response.
    func stopRecordingWithTail(delay: TimeInterval = 0.40) {
        guard recordingState == .recording else { return }
        voiceEndpointDetector = nil
        ownVoiceStopGate = nil
        delayedStopWorkItem?.cancel()
        recordingState = .transcribing
        owLog("[OpenWhisper] Hotkey released; UI transitioned to transcribing, keeping mic open for \(Int(delay * 1000))ms tail buffer...")
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        delayedStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stopRecording() {
        delayedStopWorkItem?.cancel()
        delayedStopWorkItem = nil
        voiceEndpointDetector = nil
        ownVoiceStopGate = nil

        if targetSpeakerEnrollmentIsRecording {
            stopTargetSpeakerEnrollmentRecording()
            return
        }
        guard recordingState == .recording || (recordingState == .transcribing && activeTranscriptionSession != nil) else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioEngine, let session = activeTranscriptionSession else {
            recordingMedia.end()
            owLog("[OpenWhisper] No audio engine")
            recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
            return
        }
        let segments = audioEngine.stopRecording()
        // A voice command keeps media paused until it has run (see finishTranscription).
        if !session.isVoiceCommand {
            recordingMedia.end()
        }

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

        guard let transcriber = activeTranscriptionService else {
            owLog("[OpenWhisper] No transcriber for background batch \(segmentNumber)")
            return
        }

        let filtered: TargetSpeakerFilterResult
        if session.targetSpeakerEnabled {
            owLog("[TargetSpeaker] Batch \(segmentNumber) filtering segment: samples=\(segment.samples.count), targetSpeakerEnabled=true, profileEmbeddings=\(session.targetSpeakerProfile?.embeddings.count ?? 0)")
            let result = await targetSpeakerFilter.filter(
                samples: segment.samples,
                profile: session.targetSpeakerProfile,
                enabled: true,
                audioProcessingMode: audioProcessingMode
            )
            // One coherent voice in a session whose "Jarvis" already matched the user: that
            // voice is the user. Holding it for a "Bu benim sesimdi" tap only lost commands.
            if session.wakeSpeakerVerified, result.decision == .singleSpeakerUncertain, !result.wasFailClosed {
                owLog("[TargetSpeaker] Batch \(segmentNumber) single speaker, voice already matched at the wake word — accepting")
                filtered = TargetSpeakerFilterResult(
                    samples: segment.samples,
                    acceptedSampleCount: segment.samples.count,
                    hadVoiceActivity: result.hadVoiceActivity,
                    decision: .accepted,
                    wasFailClosed: false,
                    errorDescription: nil,
                    acceptedSampleRanges: [TargetSpeakerAcceptedRange(start: 0, end: segment.samples.count)]
                )
            } else {
                filtered = result
            }
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
                        audioProcessingMode: audioProcessingMode,
                        segmentAcceptedRanges: filtered.acceptedSampleRanges
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
        // Media paused when a voice session started plays again only after its command
        // (or dictation) is done, on every exit path below. A recording started meanwhile
        // owns the pause now and releases it when it stops.
        var resumeMediaAfterCommand = true
        defer {
            if session.isVoiceCommand && recordingState != .recording {
                recordingMedia.end(resuming: resumeMediaAfterCommand)
            }
        }
        let recordingID = await recordingHistoryStore.activeRecordingID(sessionID: session.id)
        do {
            savedRecordings = try await recordingHistoryStore.finish(
                sessionID: session.id,
                keep: !session.isCancelled && !session.historySaveFailed && session.queuedSampleCount >= 6_400,
                previewText: AudioSegmentation.joinTranscripts(session.segmentTexts),
                whisperSegments: session.allSegmentTexts.count,
                trigger: session.trigger
            )
        } catch {
            lastError = "Ses geçmişi tamamlanamadı: \(error.localizedDescription)"
            owLog("[RecordingHistory] Finish failed: \(error)")
        }
        // Only kept recordings get a trace: it lives and is pruned next to their audio.
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Started: \(session.startedAt.formatted(date: .numeric, time: .standard))",
                "Source: \(session.trigger.rawValue) — \(session.trigger.title)",
                "Target app: \(session.targetApp?.bundleIdentifier ?? "unknown")",
                String(format: "Duration: %.1f s", Double(session.queuedSampleCount) / 16_000),
                "Whisper segments: \(session.allSegmentTexts)",
            ] + (savedRecordings.first { $0.id == traceID }?.stats?.logLines ?? []))
        }
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

        await VoiceTrace.$current.withValue(traceID) {
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

            // Mangled names ("Sputfayda" → "Spotify'da") fixed before routing, so a command is
            // still recognized; the list is the user's ses-benzerleri.txt.
            let (text, soundAlikes) = SoundAlikeCorrector.correct(
                AudioSegmentation.joinTranscripts(session.segmentTexts),
                entries: SoundAlikeCorrector.loadEntries()
            )
            for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("[BLANK"),
                  !trimmed.hasPrefix("(BLANK") else {
                owLog("[OpenWhisper] Empty/blank transcription, skipping")
                return
            }
            guard !AudioSegmentation.isRepetitionHallucination(trimmed) else {
                owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
                return
            }

            owLog("[OpenWhisper] Raw: \(text)")
            correctionGeneration &+= 1
            let generation = correctionGeneration

            /// Pastes `rawText` (after learned/phonetic corrections) into `targetApp`. With
            /// `send`, presses Return once the paste landed, for coding agents: the text is
            /// then gone from the field, so the swap, snapshot and LLM cleanup steps are skipped.
            @MainActor
            func pasteAsDictation(
                _ rawText: String,
                targetApp: NSRunningApplication?,
                pasteContext: PasteContext,
                send: Bool
            ) async {
                var initialText = rawText

                // Tracks which learned pairs actually fired for THIS dictation, so the paste
                // callback below can hand them to DictationSnapshot.capture for reversal detection.
                // Deliberately excludes PhoneticGlossaryCorrector's substitutions (see `phoneticApplied`
                // below) — that corrector has no corresponding CorrectionStore record to penalize.
                var appliedCorrectionPairs: [(wrong: String, right: String)] = []

                let activePairs = CorrectionStore.shared.activePairs
                if !activePairs.isEmpty {
                    let (corrected, applied) = CorrectionEngine.applyCorrections(to: initialText, pairs: activePairs)
                    if !applied.isEmpty {
                        initialText = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                        for (wrong, right) in applied {
                            owLog("[Corrections] Applied learned correction: \(wrong) -> \(right)")
                        }
                        CorrectionStore.shared.recordApplied(pairs: applied)
                        appliedCorrectionPairs = applied
                    }
                }

                let (phoneticCorrected, phoneticApplied) = PhoneticGlossaryCorrector.correct(initialText)
                if !phoneticApplied.isEmpty {
                    initialText = phoneticCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
                    for (wrong, right) in phoneticApplied {
                        owLog("[PhoneticGlossary] Corrected: \(wrong) -> \(right)")
                    }
                }

                var laughterWasRandomized = false
                if self.laughterToRandomEnabled {
                    let result = LaughterRandomizer.transform(initialText)
                    if result.didTransform {
                        initialText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        laughterWasRandomized = true
                        owLog("[LaughterRandomizer] Laughter converted to keyboard random")
                    }
                }

                self.lastTranscription = initialText
                let misheard = self.misheardWords(in: initialText)
                if !misheard.isEmpty {
                    owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text))")
                }

                if self.autoPasteEnabled {
                    // Step 1: Paste raw/corrected text INSTANTLY (3-second path)
                    self.textInjector?.pasteTextResult(
                        initialText,
                        targetApp: targetApp,
                        context: pasteContext
                    ) { [weak self] outcome in
                        // The paste callback runs outside the task: re-bind the trace so the
                        // cleanup below (and everything it logs) still lands in it.
                        Task { @MainActor in VoiceTrace.$current.withValue(traceID) {
                            guard let self else { return }
                            owLog("[Result] Paste into \(targetApp?.bundleIdentifier ?? "unknown"): \(outcome) — '\(initialText)'")
                            switch outcome {
                            case .pastedVerified where send, .pastedUnverified where send:
                                self.swapPair = nil
                                self.swapPasteContext = nil
                                self.hotkey?.setSwapAvailable(false)
                                // Electron composers and CLI bracketed paste need a moment to
                                // take the paste before Return, or only part of it is sent.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                                    MainActor.assumeIsolated {
                                        guard let self else { return }
                                        let sent = pasteContext.targetPID.map {
                                            (self.textInjector as? TextInjector)?.pressReturn(inPID: $0) ?? false
                                        } ?? false
                                        owLog("[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                                        if let traceID {
                                            VoiceEventLog.shared.append(traceID, "[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                                        }
                                        self.showFlowBarMessage(sent ? "gönderildi" : "yazıldı, gönderilmedi", durationMs: 1200)
                                    }
                                }
                            case .pastedVerified, .pastedUnverified:
                                self.swapPair = DictationPair(raw: rawText, cleaned: initialText)
                                self.swapTargetApp = targetApp
                                self.swapPasteContext = pasteContext.contextForInjectedText(initialText)
                                self.lastInjectedIsCleaned = false
                                self.lastInjectedText = initialText
                                self.hotkey?.setSwapAvailable(true)
                                DictationSnapshot.shared.capture(
                                    pastedText: initialText,
                                    targetApp: targetApp,
                                    appliedPairs: appliedCorrectionPairs
                                )

                                self.dismissFlowBarMessage()

                                // Step 2: Run LLM Cleanup asynchronously in background (7-second path).
                                // Once Ollama finishes, replace the initially pasted text in-place.
                                // Keep the generated keyboard random exact. LLM cleanup can rewrite
                                // or remove a random-looking token, which would defeat this setting.
                                if self.llmCleanupEnabled && self.cleanupAvailable && !laughterWasRandomized {
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        let cleaned = await self.llmCleanup?.cleanup(text: initialText, misheard: misheard) ?? initialText
                                        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

                                        guard !trimmedCleaned.isEmpty, trimmedCleaned != initialText else { return }
                                        // A corrected word can reveal a voice command ("Sesifullah"
                                        // → "Sesi fulle"): take the dictation back out and run it.
                                        if !misheard.isEmpty,
                                           !LLMCleanup.sameWords(trimmedCleaned, initialText),
                                           await self.runCorrectedDictationAsCommand(
                                            pasted: initialText, corrected: trimmedCleaned,
                                            generation: generation, session: session, targetApp: targetApp
                                           ) {
                                            return
                                        }
                                        owLog("[OpenWhisper] Async LLM cleanup complete: '\(trimmedCleaned)'. Replacing initial text...")

                                        self.textInjector?.replaceInjectedText(
                                            oldText: initialText,
                                            newText: trimmedCleaned,
                                            targetApp: targetApp,
                                            context: self.swapPasteContext
                                        ) { [weak self] in
                                            Task { @MainActor in
                                                guard let self else { return }
                                                self.swapPair = DictationPair(raw: rawText, cleaned: trimmedCleaned)
                                                self.swapPasteContext = self.swapPasteContext?.contextAfterReplacingInjectedText(with: trimmedCleaned)
                                                self.lastTranscription = trimmedCleaned
                                                self.lastInjectedIsCleaned = true
                                                self.lastInjectedText = trimmedCleaned
                                                self.textInjector?.copyToClipboard(rawText)
                                                self.showFlowBarMessage("fixed", durationMs: 1000)
                                                // The field now holds the LLM-cleaned text, not what
                                                // was captured at the raw paste above — without this,
                                                // every later diff compares raw-vs-cleaned and can
                                                // learn the LLM's own edits as if the user made them.
                                                // `capture` re-runs the same suppressNextCapture check
                                                // as the original call (see `install`), so an
                                                // intervening Option+Z swap still correctly discards
                                                // this recapture instead of resurrecting a snapshot
                                                // for text the user already threw away.
                                                DictationSnapshot.shared.capture(
                                                    pastedText: trimmedCleaned,
                                                    targetApp: targetApp,
                                                    appliedPairs: appliedCorrectionPairs
                                                )
                                                owLog("[OpenWhisper] Async LLM replacement finished.")
                                                if let traceID {
                                                    VoiceEventLog.shared.append(traceID, "[Result] Replaced pasted text with cleanup: '\(trimmedCleaned)'")
                                                }
                                            }
                                        }
                                    }
                                }
                            case .clipboardOnly(let reason):
                                self.swapPair = nil
                                self.swapPasteContext = nil
                                self.hotkey?.setSwapAvailable(false)
                                self.showFlowBarMessage(self.clipboardOnlyMessage(for: reason))
                            }
                        } }
                    }
                } else {
                    self.textInjector?.copyToClipboard(initialText)
                    owLog("[Result] Auto-paste off, copied to clipboard: '\(initialText)'")
                }
            }

            // "Claude Code'a / Codex'e şunu yaz … gönder": checked before reminders and
            // Spotify so a prompt that mentions them is still typed, not executed. A bare
            // trailing "gönder" only counts in agent apps and terminals.
            if let agent = AgentCommandParser.parse(trimmed),
               agent.target != nil || AgentApp.sendCapableBundleIdentifiers.contains(session.targetApp?.bundleIdentifier ?? "") {
                owLog("[Route] agent (\(agent.target?.displayName ?? "frontmost app"), send: \(agent.send))")
                guard !agent.body.isEmpty else {
                    owLog("[Agent] Nothing to write after the command words, skipping")
                    return
                }
                var targetApp = session.targetApp
                var pasteContext = session.pasteContext
                if let target = agent.target,
                   !(targetApp?.bundleIdentifier.map(target.bundleIdentifiers.contains) ?? false) {
                    guard let app = await AgentAppActivator.activate(target) else {
                        self.textInjector?.copyToClipboard(agent.body)
                        self.showFlowBarMessage("\(target.displayName) açılamadı, panoya kopyalandı")
                        if session.isVoiceCommand {
                            await self.speakReply(self.jarvisReply.failure("\(target.displayName) açılamadı"))
                        }
                        return
                    }
                    targetApp = app
                    pasteContext = PasteContext.capture(targetApp: app)
                }
                await pasteAsDictation(agent.body, targetApp: targetApp, pasteContext: pasteContext, send: agent.send)
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }
                return
            }

            // A "Jarvis" session ending in "yaz" ("… bunu yaz", "… yazsana") is always typed, even
            // when it reads like a command. A trailing "gönder" outside agent apps is typed too,
            // without Return, so Slack / Mail are never sent by voice.
            if session.isVoiceCommand {
                let typed = JarvisAddressee.trailingTypeCommand(trimmed)
                    ?? AgentCommandParser.parse(trimmed).flatMap { $0.send && !$0.body.isEmpty ? $0.body : nil }
                if let typed {
                    owLog("[Route] typed by trailing command: '\(typed)'")
                    await pasteAsDictation(typed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
                    await self.speakReply(self.jarvisReply.agent(sent: false))
                    return
                }
            }

            // "Bluetooth'u kapat", "Wi-Fi'yi aç", "kulaklığın bağlantısını kes": only in a
            // Jarvis session, so dictating the same words with the hotkey still types them.
            // A Jarvis session can run on after the command ("Şarkıyı durdur. Neden. Var öyle…"
            // when the user turns to someone else): if the whole transcript is no command, the
            // first sentence alone may be.
            let firstSentence = session.isVoiceCommand ? Self.leadingSentence(of: trimmed) : nil
            func parseSystem(_ candidate: String) -> SystemCommand? {
                SystemCommandParser.parse(
                    candidate,
                    installedApps: SystemController.installedApps(),
                    shortcuts: candidate.range(of: SystemCommandParser.shortcutMention, options: [.regularExpression, .caseInsensitive]) != nil
                        ? SystemController.shortcutNames() : []
                )
            }
            if session.isVoiceCommand,
               let command = parseSystem(trimmed) ?? firstSentence.flatMap(parseSystem) {
                owLog("[Route] system (\(command))")
                // Going to sleep or locking: say it before the Mac stops listening.
                let speaksFirst = ([.sleep, .displaySleep, .lockScreen] as [SystemCommand]).contains(command)
                if speaksFirst { await self.speakReply("Görüşürüz.") }
                let status = await SystemController.perform(command)
                owLog("[Result] System command: \(status)")
                self.lastTranscription = text
                self.showFlowBarMessage(status, durationMs: status.count > 40 ? 6000 : 2500)
                if !speaksFirst { await self.speakReply(self.jarvisReply.system(command, status: status)) }
                return
            }

            // A "Jarvis" session that isn't a command is talk to Jarvis only when the LLM is
            // fairly sure it was said to him; talk to someone else, a message being dictated, or
            // anything in between is typed. With Claude Code, Codex or a terminal running them in
            // front it's a prompt for them and is typed. Fn dictation is always typed.
            @MainActor func dictateOrChat() async {
                let front = session.targetApp?.bundleIdentifier
                if session.isVoiceCommand, !AgentApp.isAgentFront(front) {
                    let score = self.ollamaAvailable
                        ? await JarvisAddressee.score(
                            text: trimmed,
                            frontApp: session.targetApp?.localizedName,
                            lastReply: JarvisChat.shared.recentReply,
                            model: self.ollamaModel)
                        : nil
                    let minScore = JarvisAddressee.minScore
                    let forJarvis = JarvisAddressee.isForJarvis(score: score, minScore: minScore)
                    owLog("[Addressee] score \(score.map(String.init) ?? "none") / threshold \(minScore) → \(forJarvis ? "chat" : "type") (front: \(front ?? "none"))")
                    if forJarvis {
                        self.lastTranscription = text
                        await self.chatReply(to: trimmed)
                        return
                    }
                }
                await pasteAsDictation(trimmed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
            }

            let isReminderCommand = ReminderManager.isReminder(text)
            var commandText = text
            var isSpotifyCommand = await SpotifyManager.isSpotifyCommand(
                text, ollamaAvailable: self.ollamaAvailable, commandMode: session.isVoiceCommand
            )
            if !isSpotifyCommand, !isReminderCommand, let firstSentence,
               await SpotifyManager.isSpotifyCommand(firstSentence, ollamaAvailable: self.ollamaAvailable, commandMode: true) {
                owLog("[Route] first sentence is the command: '\(firstSentence)'")
                commandText = firstSentence
                isSpotifyCommand = true
            }
            owLog("[Route] \(isReminderCommand ? "reminder" : isSpotifyCommand ? "spotify" : "dictation")")
            if isReminderCommand {
                owLog("[OpenWhisper] Reminder detected: \(text)")
                self.lastTranscription = text
                if self.ollamaAvailable {
                    let scheduled = await self.reminderManager?.handleReminder(text: text) ?? false
                    owLog("[Result] Reminder \(scheduled ? "scheduled" : "not scheduled")")
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.reminder(scheduled: scheduled)) }
                } else {
                    owLog("[OpenWhisper] Cannot set reminder — Ollama not available")
                }
            } else if isSpotifyCommand {
                owLog("[OpenWhisper] Spotify command detected: \(commandText)")
                let resumesMedia = SpotifyManager.resumesPausedMedia(afterCommand: commandText)
                let misheard = self.cleanupAvailable ? self.misheardWords(in: commandText) : []
                let handled = await SpotifyManager.shared.handleCommand(
                    text: commandText, targetApp: session.targetApp, recordUndo: !misheard.isEmpty
                )
                owLog("[Result] Spotify command \(handled ? "handled" : "not applied")")
                if handled {
                    resumeMediaAfterCommand = resumesMedia
                    self.lastTranscription = text
                    // Never "şarkı çalınıyor": only a short ack, spoken before the music resumes.
                    if session.isVoiceCommand {
                        await self.speakReply(self.jarvisReply.spotify(handled: true))
                    }
                    if !misheard.isEmpty {
                        owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text)); checking the command again")
                        Task { @MainActor [weak self] in
                            await self?.rerunCorrectedCommand(
                                commandText, misheard: misheard, generation: generation, session: session
                            )
                        }
                    }
                } else {
                    owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                    await dictateOrChat()
                }
            } else {
                await dictateOrChat()
            }
        }
    }

    // MARK: - Voice replies

    /// Speaks Jarvis's reply and waits for it, so music paused for the command resumes only
    /// after he is done. Silent when the setting is off or a new recording already started.
    private func speakReply(_ reply: String?) async {
        guard let reply, voiceRepliesEnabled, recordingState != .recording else { return }
        owLog("[Voice] Reply: '\(reply)'")
        await JarvisVoice.shared.speak(reply) { [weak self] in self?.jarvisActivity = .speaking }
        jarvisActivity = .none
    }

    /// A "Jarvis" session that is no command and not meant for Claude Code / Codex: the user is
    /// talking to Jarvis, so the local LLM answers out loud. The voice starts on the first
    /// sentence while the rest is still being written. Without a voice the answer is shown.
    private func chatReply(to text: String) async {
        guard ollamaAvailable else {
            owLog("[Chat] Ollama not available")
            showFlowBarMessage("Ollama kapalı, sohbet edemiyorum")
            await speakReply(jarvisReply.failure("yerel model şu an kapalı"))
            return
        }
        jarvisActivity = .thinking
        defer { jarvisActivity = .none }
        let sentences = JarvisChat.shared.reply(to: text, model: ollamaModel)
        var heard = false
        if voiceRepliesEnabled, recordingState != .recording {
            heard = await JarvisVoice.shared.speak(sentences: sentences) { [weak self] in self?.jarvisActivity = .speaking }
        } else {
            for await _ in sentences {}
        }
        if !heard, recordingState != .recording, let answer = JarvisChat.shared.lastReply, !answer.isEmpty {
            showFlowBarMessage(answer, durationMs: min(max(answer.count * 60, 3000), 10000))
        }
    }

    // MARK: - Misheard word correction

    /// Words in `text` that are neither Turkish nor English, minus the user's own glossary
    /// terms and learned corrections, which are often not dictionary words either.
    private func misheardWords(in text: String) -> [MisheardWordDetector.Word] {
        let locale = Locale(identifier: "tr_TR")
        var ignoring = Set((GlossaryStore.terms() ?? []).flatMap { MisheardWordDetector.words(in: $0) }
            .map { $0.lowercased(with: locale) })
        for pair in CorrectionStore.shared.activePairs {
            ignoring.formUnion(MisheardWordDetector.words(in: pair.right).map { $0.lowercased(with: locale) })
        }
        return MisheardWordDetector.find(in: text, ignoring: ignoring)
    }

    /// A correction may only act while nothing newer happened: no newer transcript and no
    /// recording in progress (a volume revert would also undo the recording's ducking).
    private func correctionIsCurrent(_ generation: UInt64) -> Bool {
        correctionGeneration == generation && recordingState == .idle
    }

    /// A Spotify command ran on a transcript with misheard words. Corrects the transcript in
    /// the background; if it then asks for another command, the first one is undone and the
    /// corrected one runs (see `SpotifyManager.rerunIfCorrected`).
    private func rerunCorrectedCommand(
        _ text: String,
        misheard: [MisheardWordDetector.Word],
        generation: UInt64,
        session: RecordingTranscriptionSession
    ) async {
        guard let llmCleanup else { return }
        let corrected = await llmCleanup.cleanup(text: text, misheard: misheard)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LLMCleanup.sameWords(corrected, text) else {
            owLog("[Misheard] Command '\(text)' unchanged after correction")
            return
        }
        owLog("[Misheard] Command corrected: '\(text)' → '\(corrected)'")
        guard correctionIsCurrent(generation),
              await SpotifyManager.isSpotifyCommand(
                corrected, ollamaAvailable: ollamaAvailable, commandMode: session.isVoiceCommand
              ),
              correctionIsCurrent(generation) else { return }
        if await SpotifyManager.shared.rerunIfCorrected(original: text, corrected: corrected, targetApp: session.targetApp) {
            showFlowBarMessage("fixed", durationMs: 1000)
        }
    }

    /// A dictation was pasted, and its correction turned out to be a Spotify command. Deletes
    /// the pasted text and runs the command. Returns false (the caller then pastes the
    /// correction as usual) if it isn't a command or the text couldn't be deleted safely.
    private func runCorrectedDictationAsCommand(
        pasted: String,
        corrected: String,
        generation: UInt64,
        session: RecordingTranscriptionSession,
        targetApp: NSRunningApplication?
    ) async -> Bool {
        guard correctionIsCurrent(generation),
              let injector = textInjector as? TextInjector,
              await SpotifyManager.isSpotifyCommand(
                corrected, ollamaAvailable: ollamaAvailable, commandMode: session.isVoiceCommand
              ),
              correctionIsCurrent(generation) else { return false }
        let deleted = await withCheckedContinuation { continuation in
            injector.deleteInjectedText(pasted, targetApp: targetApp, context: swapPasteContext) {
                continuation.resume(returning: $0)
            }
        }
        guard deleted else {
            owLog("[Misheard] '\(corrected)' is a command, but the pasted text couldn't be deleted; keeping it as text")
            return false
        }
        owLog("[Misheard] Dictation '\(pasted)' was the command '\(corrected)'")
        swapPair = nil
        swapPasteContext = nil
        hotkey?.setSwapAvailable(false)
        if await SpotifyManager.shared.handleCommand(text: corrected, targetApp: targetApp) {
            lastTranscription = corrected
            showFlowBarMessage("fixed", durationMs: 1000)
        }
        return true
    }

    /// Re-runs the selected saved audio through the current recognition and text settings.
    /// Replays never paste into another application or trigger voice commands.
    func replayRecording(_ recording: SavedRecording) {
        recordingPreviewTask?.cancel()
        guard replayingRecordingID == nil else { return }
        guard recordingState == .idle && pendingTranscriptionCount == 0 else {
            replayStatus = "Önce mevcut ses kaydının işlenmesini bekleyin."
            return
        }
        replayingRecordingID = recording.id
        replayStatus = "Kayıt yeniden analiz ediliyor…"
        Task { @MainActor in
            defer { replayingRecordingID = nil }
            let session = RecordingTranscriptionSession(
                id: 0,
                targetApp: nil,
                targetSpeakerEnabled: targetSpeakerFiltersTranscription,
                targetSpeakerProfile: targetSpeakerProfile,
                pasteContext: PasteContext.initial(targetApp: nil)
            )
            do {
                var frame: Int64 = 0
                while let (segment, nextFrame) = try await recordingHistoryStore.segment(id: recording.id, startingAt: frame) {
                    await transcribeStreamingSegment(segment, session: session)
                    frame = nextFrame
                }
                var output = AudioSegmentation.joinTranscripts(session.segmentTexts)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty, !output.hasPrefix("[BLANK"), !output.hasPrefix("(BLANK") else {
                    replayStatus = "Bu kayıttan metin çıkarılamadı."
                    return
                }
                output = CorrectionEngine.applyCorrections(to: output, pairs: CorrectionStore.shared.activePairs).0
                output = PhoneticGlossaryCorrector.correct(output).0
                if laughterToRandomEnabled {
                    output = LaughterRandomizer.transform(output).text
                } else if llmCleanupEnabled && cleanupAvailable {
                    output = await llmCleanup?.cleanup(text: output) ?? output
                }
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty else {
                    replayStatus = "Bu kayıttan metin çıkarılamadı."
                    return
                }
                textInjector?.copyToClipboard(output)
                replayStatus = "Yeniden analiz edildi ve panoya kopyalandı."
                do {
                    savedRecordings = try await recordingHistoryStore.updatePreview(id: recording.id, text: output)
                } catch {
                    owLog("[RecordingHistory] Replay preview save failed: \(error)")
                }
            } catch {
                replayStatus = "Kayıt açılamadı: \(error.localizedDescription)"
            }
        }
    }

    /// Older saved audio predates transcript previews. Fill those labels in the background
    /// when the menu is opened, without changing or deleting any recording.
    func prepareRecordingPreviews() {
        guard modelLoaded, recordingPreviewTask == nil,
              savedRecordings.contains(where: { $0.previewText == nil }) else { return }
        recordingPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingPreviewTask = nil }
            for recording in self.savedRecordings where recording.previewText == nil {
                guard !Task.isCancelled,
                      self.recordingState == .idle,
                      self.pendingTranscriptionCount == 0,
                      !self.systemAudioIsRecording,
                      !self.systemAudioIsTranscribing,
                      self.replayingRecordingID == nil else { return }
                let session = RecordingTranscriptionSession(
                    id: 0,
                    targetApp: nil,
                    targetSpeakerEnabled: self.targetSpeakerFiltersTranscription,
                    targetSpeakerProfile: self.targetSpeakerProfile,
                    pasteContext: PasteContext.initial(targetApp: nil)
                )
                do {
                    var frame: Int64 = 0
                    while !Task.isCancelled,
                          let (segment, nextFrame) = try await self.recordingHistoryStore.segment(id: recording.id, startingAt: frame) {
                        await self.transcribeStreamingSegment(segment, session: session)
                        frame = nextFrame
                    }
                    guard !Task.isCancelled else { return }
                    self.savedRecordings = try await self.recordingHistoryStore.updatePreview(
                        id: recording.id,
                        text: AudioSegmentation.joinTranscripts(session.segmentTexts)
                    )
                } catch {
                    owLog("[RecordingHistory] Preview could not be prepared: \(error)")
                }
            }
        }
    }

    // MARK: - Flow Bar Visibility

    /// The flow bar is invisible while idle and only appears for the duration of an active
    /// dictation (recording through transcribing/pasting), so the app runs invisibly in the
    /// background otherwise — the menu bar icon remains the only always-visible element.
    private func syncFlowBarVisibility() {
        // Keep a reachable finish control onscreen while the system output is being heard,
        // even if the normal microphone flow bar is disabled in Settings.
        if systemAudioEnabled {
            flowBarController?.show()
            return
        }
        guard flowBarEnabled else {
            flowBarController?.hide()
            return
        }
        if recordingState == .idle && flowBarMessage == nil && jarvisActivity == .none {
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
            swapPasteContext = nil
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
        case .targetFieldChanged:
            return "Yapıştırılamadı — hedef alan değişmiş (metin panoda)"
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
        discardActiveRecording(reason: "Fn+Z swap")
    }

    /// Stops the microphone and throws the audio away: no transcription, no injection.
    private func discardActiveRecording(reason: String) {
        voiceEndpointDetector = nil
        ownVoiceStopGate = nil
        guard recordingState == .recording, let session = activeTranscriptionSession else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        session.isCancelled = true
        session.continuation.finish()
        session.task?.cancel()
        activeTranscriptionSession = nil
        _ = audioEngine?.stopRecording()  // discard captured samples — no transcription
        recordingMedia.end()
        recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
        recordingDuration = 0
        audioLevel = 0
        owLog("[OpenWhisper] Recording cancelled (\(reason))")
    }

    // MARK: - Target Speaker Enrollment

    private func invalidateTargetSpeakerEnrollmentWork() {
        targetSpeakerEnrollmentGeneration &+= 1
        targetSpeakerEnrollmentTask?.cancel()
        targetSpeakerEnrollmentTask = nil
    }

    @discardableResult
    private func teardownTargetSpeakerEnrollmentRecording() -> [Float] {
        let wasRecording = targetSpeakerEnrollmentIsRecording
        defer { if wasRecording { recordingMedia.end() } }
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

    // MARK: - On-demand target speaker sample capture

    func startTargetSpeakerSampleRecording() {
        owLog("[TargetSpeaker] startTargetSpeakerSampleRecording called")
        guard recordingState == .idle,
              canCaptureTargetSpeakerSample,
              targetSpeakerProfile != nil,
              let audioEngine else {
            owLog("[TargetSpeaker] startTargetSpeakerSampleRecording skipped (state=\(recordingState), canCapture=\(canCaptureTargetSpeakerSample), hasProfile=\(targetSpeakerProfile != nil))")
            return
        }

        clearFlowBarMessage()

        if audioDuckingEnabled {
            recordingMedia.begin()
        }

        targetSpeakerSampleIsRecording = true
        targetSpeakerSampleStatus = "Kaydediliyor — tanınmadığın koşulda konuş (en fazla 30 sn)."
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil
        audioEngine.startRecording(
            deviceUID: resolvedInputDeviceUID,
            audioProcessingMode: audioProcessingMode,
            levelCallback: { [weak self] rawLevel in
                let target = AudioSignalProcessor.displayLevel(forRawRMS: rawLevel)
                Task { @MainActor in
                    guard let self else { return }
                    self.audioLevel = target
                }
            }
        )
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.targetSpeakerSampleIsRecording else { return }
                self.recordingDuration = min(
                    self.recordingDuration + 0.25,
                    TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                )
                if self.recordingDuration >= TargetSpeakerFilterConfiguration.maximumEnrollmentDuration {
                    owLog("[TargetSpeaker] Sample recording reached max duration 30s")
                    self.stopTargetSpeakerSampleRecording()
                }
            }
        }
    }

    func stopTargetSpeakerSampleRecording() {
        owLog("[TargetSpeaker] stopTargetSpeakerSampleRecording called")
        guard targetSpeakerSampleIsRecording else { return }
        let samples = teardownTargetSpeakerSampleRecording()

        guard !samples.isEmpty else {
            targetSpeakerSampleStatus = "Kayıt alınamadı; tekrar deneyin."
            owLog("[TargetSpeaker] Sample recording returned 0 samples")
            return
        }
        guard let profile = targetSpeakerProfile else {
            targetSpeakerSampleStatus = "Önce \"Sesimi kaydet\" ile profil oluşturmalısın."
            return
        }

        owLog("[TargetSpeaker] Sample recording stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")
        appendTargetSpeakerSample(samples, to: profile)
    }

    /// Shared append boundary so the capture path and deterministic state tests agree.
    func appendTargetSpeakerSample(_ samples: [Float], to profile: TargetSpeakerProfile) {
        targetSpeakerSampleIsProcessing = true
        targetSpeakerSampleStatus = "Örnek doğrulanıyor…"
        // The profile records the processing chain it was built under and `appendConfirmedCandidate`
        // rejects a mismatch outright, so pass the mode actually in use rather than the parameter
        // default — otherwise every append fails with a confusing incompatibility error.
        let mode = audioProcessingMode
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.targetSpeakerSampleIsProcessing = false }
            do {
                let receipt = try await self.targetSpeakerFilter.appendConfirmedCandidateWithReceipt(
                    samples,
                    to: profile,
                    store: self.targetSpeakerProfileStore,
                    audioProcessingMode: mode
                )
                let added = receipt.appendedProfile.embeddings.count - receipt.previousProfile.embeddings.count
                self.targetSpeakerProfile = receipt.appendedProfile
                self.refreshTargetSpeakerProfileCoherence()
                self.hasStoredTargetSpeakerProfile = true
                self.targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                self.lastConfirmedAppendReceipt = receipt
                self.targetSpeakerSampleStatus =
                    "\(added) örnek eklendi — profilde toplam \(receipt.appendedProfile.embeddings.count)."
                owLog("[TargetSpeaker] On-demand sample appended: +\(added), new count=\(receipt.appendedProfile.embeddings.count)")
            } catch {
                self.targetSpeakerSampleStatus = error.localizedDescription
                self.lastError = error.localizedDescription
                owLog("[TargetSpeaker] On-demand sample append failed: \(error)")
            }
        }
    }

    private func teardownTargetSpeakerSampleRecording() -> [Float] {
        let wasRecording = targetSpeakerSampleIsRecording
        defer { if wasRecording { recordingMedia.end() } }
        recordingTimer?.invalidate()
        recordingTimer = nil
        let samples: [Float]
        if targetSpeakerSampleIsRecording {
            samples = (audioEngine?.stopRecording() ?? []).flatMap(\.samples)
        } else {
            samples = []
        }
        targetSpeakerSampleIsRecording = false
        if recordingState == .recording {
            recordingState = .idle
        }
        recordingDuration = 0
        audioLevel = 0
        return samples
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
            recordingMedia.begin()
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
                let target = AudioSignalProcessor.displayLevel(forRawRMS: rawLevel)
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

        textInjector?.replaceInjectedText(
            oldText: oldText,
            newText: newText,
            targetApp: swapTargetApp,
            context: swapPasteContext
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.swapPasteContext = self.swapPasteContext?.contextAfterReplacingInjectedText(with: newText)
                self.textInjector?.copyToClipboard(backupText)
                self.isSwapping = false
            }
        }

        lastInjectedIsCleaned = newIsCleaned
        lastInjectedText = newText
        owLog("[OpenWhisper] Swap committed — toggle to \(newIsCleaned ? "Ollama sonrası (cleaned)" : "Ollama öncesi (raw)") text")
    }

    // MARK: - Refresh

    /// Handles openwhisper://start | stop | toggle, used by Siri Vocal Shortcuts / Shortcuts.
    func handleExternalURL(_ url: URL) {
        guard url.scheme?.lowercased() == "openwhisper" else { return }
        let action = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let hotkey else {
            owLog("[OpenWhisper] URL trigger '\(action)' ignored — setup not finished yet")
            return
        }
        owLog("[OpenWhisper] URL trigger: \(action)")
        switch action {
        case "start": startVoiceSession()
        case "stop": hotkey.externalStopHandsFree()
        case "toggle", "":
            armVoiceAutoStopForNextRecording = hotkey.isIdle
            hotkey.externalToggleHandsFree()
        default: owLog("[OpenWhisper] Unknown URL action: \(action)")
        }
    }

    /// Voice-started sessions (Vocal Shortcuts, openwhisper://start) have nobody at the keyboard, so unlike
    /// Fn they end themselves on silence. Start-only: no-op while anything is recording.
    func startVoiceSession(trigger: RecordingTrigger = .external) {
        guard let hotkey, hotkey.isIdle else { return }
        armVoiceAutoStopForNextRecording = true
        hotkey.externalStartHandsFree(trigger: trigger)
        // Load the model while the user is still speaking; after an idle night Ollama has
        // unloaded it and the cold load alone outlasts a command's wait.
        if ollamaAvailable {
            let model = SpotifyManager.selectedOllamaModel
            Task.detached { await LLMCleanup.warmUp(model: model) }
        }
    }

    // MARK: - Wake word

    private func setupWakeWordListener() {
        let listener = WakeWordListener { [weak self] audio, score in
            MainActor.assumeIsolated { self?.handleDirectWake(audio: audio, score: score) }
        }
        listener.onCandidate = { [weak self] audio, peak in
            MainActor.assumeIsolated { self?.verifyWakeCandidate(audio: audio, peak: peak) }
        }
        listener.prepare()
        wakeWordListener = listener
        let mediaMonitor = SystemMediaActivityMonitor { [weak self] playing in
            guard let self else { return }
            self.mediaPlaying = playing
            self.wakeWordListener?.setMediaPlaying(playing)
            self.updateWakeWordListener()
        }
        mediaActivityMonitor = mediaMonitor
        mediaMonitor.start()
        observeSleepForWakeWord()
        updateWakeWordListener()
        prepareWakeSpeakerModel()
    }

    /// Score above the direct threshold: start listening at once, so words right after
    /// "Jarvis" aren't lost. With "Yalnızca Benim Sesim" the speaker check runs meanwhile: a
    /// match lets the recording through as the user's; no match doesn't end the session (the
    /// wake-time check scored the real user 0.11–0.38 about half the time, 26 Sep 2026), the
    /// recording's own speaker filter decides, and a weak "Jarvis" must still be confirmed by
    /// Whisper.
    private func handleDirectWake(audio: [Float], score: Float) {
        owLog("[OpenWhisper] Voice session requested (wake word)")
        pendingWakeSpeakerVerified = false
        startVoiceSession(trigger: .wakeWord)
        guard targetSpeakerGuardsWakeWord else {
            if score < WakeWordListener.confirmedScore { confirmDirectWake(audio: audio, score: score) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if await self.wakeSpeakerMatches(audio: audio) {
                self.markWakeSpeakerVerified()
            } else if score < WakeWordListener.confirmedScore {
                self.confirmDirectWake(audio: audio, score: score)
            } else {
                owLog("[WakeWord] Voice not matched at the wake word; the recording's speaker filter decides")
            }
        }
    }

    private func markWakeSpeakerVerified() {
        if recordingState == .recording, let session = activeTranscriptionSession, session.trigger == .wakeWord {
            session.wakeSpeakerVerified = true
        } else {
            pendingWakeSpeakerVerified = true
        }
    }

    /// A weak direct detection: the session is already recording (no added latency) while
    /// Whisper checks the clip for "Jarvis"; without it the recording is dropped untranscribed.
    private func confirmDirectWake(audio: [Float], score: Float) {
        guard let transcriber = activeTranscriptionService else { return }
        wakeConfirmationID &+= 1
        let id = wakeConfirmationID
        let started = Date()
        Task { [weak self] in
            let verdict = await WakeWordVerifier.heardWakeWord(audio: audio, transcriber: transcriber)
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch verdict {
            case .accepted(let why):
                owLog(String(format: "[WakeWord] Weak detection %.2f confirmed in %d ms — %@", score, ms, why))
            case .rejected(let why):
                guard id == self.wakeConfirmationID, self.recordingState == .recording else {
                    owLog(String(format: "[WakeWord] Weak detection %.2f rejected in %d ms, session already over — %@", score, ms, why))
                    return
                }
                owLog(String(format: "[WakeWord] Weak detection %.2f rejected in %d ms — discarding session: %@", score, ms, why))
                self.hotkey?.externalCancelHandsFree()
                self.discardActiveRecording(reason: "wake word not confirmed")
            }
        }
    }

    /// Whether the wake clip sounds like the enrolled user; true when the check is off. A model
    /// error lets the wake through: a failed download must not silence "Jarvis" altogether.
    private func wakeSpeakerMatches(audio: [Float]) async -> Bool {
        guard targetSpeakerGuardsWakeWord, let profile = targetSpeakerProfile else { return true }
        let threshold = TargetSpeakerFilter.wakeThreshold
        let started = Date()
        do {
            let score = try await targetSpeakerFilter.wakeSpeakerScore(samples: audio, profile: profile)
            let matched = score >= threshold
            owLog(String(format: "[WakeWord] Speaker %@ (score %.3f, threshold %.2f, %d ms)",
                         matched ? "matched" : "rejected", score, threshold,
                         Int(Date().timeIntervalSince(started) * 1000)))
            return matched
        } catch {
            owLog("[WakeWord] Speaker check failed, allowing wake: \(error)")
            return true
        }
    }

    /// Loads the speaker model in the background so the first guarded "Jarvis" isn't slowed by it.
    private func prepareWakeSpeakerModel() {
        guard targetSpeakerGuardsWakeWord else { return }
        let filter = targetSpeakerFilter
        Task.detached(priority: .utility) {
            do { try await filter.prepareModel() } catch {
                owLog("[WakeWord] Speaker model preparation failed: \(error)")
            }
        }
    }

    /// Grey-zone wake score: Whisper must hear "Jarvis" and the LLM must judge it a call rather
    /// than a song or talk about Jarvis (`WakeWordVerifier`). One check at a time.
    private func verifyWakeCandidate(audio: [Float], peak: Float) {
        guard !wakeCandidateVerifying, let transcriber = activeTranscriptionService,
              let hotkey, hotkey.isIdle else { return }
        wakeCandidateVerifying = true
        let mediaPlaying = self.mediaPlaying
        let ollama = ollamaAvailable
        let model = SpotifyManager.selectedOllamaModel
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            // A voice mismatch alone no longer drops the call (see `handleDirectWake`); Whisper
            // and the LLM below still have to hear a real "Jarvis".
            let speakerMatched = self.targetSpeakerGuardsWakeWord ? await self.wakeSpeakerMatches(audio: audio) : false
            let verdict = await WakeWordVerifier.verify(
                audio: audio, transcriber: transcriber, mediaPlaying: mediaPlaying,
                ollamaAvailable: ollama, model: model
            )
            self.wakeCandidateVerifying = false
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch verdict {
            case .accepted(let why):
                owLog(String(format: "[WakeWord] Candidate %.2f accepted in %d ms — %@", peak, ms, why))
                self.pendingWakeSpeakerVerified = speakerMatched
                self.startVoiceSession(trigger: .wakeWord)
            case .rejected(let why):
                owLog(String(format: "[WakeWord] Candidate %.2f rejected in %d ms — %@", peak, ms, why))
            }
        }
    }

    /// System sleep stops the listener; `didWake` only arrives on a full wake, so the DarkWakes of
    /// Power Nap never reopen the mic. With the display asleep and nothing playing, the open mic
    /// would be the only thing keeping the Mac from idle sleep, so the listener pauses then too.
    private func observeSleepForWakeWord() {
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, (AppState) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
        ]
        sleepObservers = handlers.map { name, apply in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    owLog("[WakeWord] \(name.rawValue)")
                    apply(self)
                    self.updateWakeWordListener()
                }
            }
        }
    }

    /// One microphone user at a time: the listener runs while enabled and nothing else
    /// (dictation, enrollment, system-audio capture) is recording.
    private func updateWakeWordListener() {
        guard let listener = wakeWordListener else { return }
        let busy = recordingState == .recording || targetSpeakerEnrollmentIsRecording || systemAudioEnabled
        let paused = systemAsleep || (screensAsleep && !mediaPlaying)
        let shouldRun = wakeWordEnabled && modelLoaded && !busy && !paused
        if shouldRun && !listener.isRunning {
            listener.start()
        } else if !shouldRun && listener.isRunning {
            listener.stop()
        }
        wakeWordListening = listener.isRunning
        wakeWordStatus = if !wakeWordEnabled { "Kapalı" }
            else if listener.isRunning { "“Jarvis” deyince dinlemeye başlar" }
            else if paused { "Uykuda — duraklatıldı" }
            else if busy { "Kayıt sırasında duraklatıldı" }
            else if !modelLoaded { "Model bekleniyor" }
            else { "Mikrofon açılamadı" }
    }

    /// The first sentence when the transcript has more than one, for a command followed by
    /// talk that wasn't meant for Jarvis.
    nonisolated static func leadingSentence(of text: String) -> String? {
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return nil }
        let first = text[...end].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[text.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || first.split(separator: " ").count < 2 ? nil : first
    }

    /// FlowBar stop button: finish and process, exactly like Enter/Space.
    func finishHandsFreeRecording() {
        hotkey?.externalStopHandsFree()
    }

    private func feedVoiceEndpoint(rawRMS: Float, at time: TimeInterval) {
        guard recordingState == .recording, var detector = voiceEndpointDetector else { return }
        let decision = detector.process(rms: rawRMS, at: time)
        voiceEndpointDetector = detector
        // Tuning aid: once a second, the level against the floor and end threshold.
        if time - lastVoiceEndpointTrace >= 1 {
            lastVoiceEndpointTrace = time
            owLog(String(format: "[VoiceAutoStop] level %.1f dBFS — ", VoiceEndpointDetector.dBFS(fromRMS: rawRMS)) + detector.summary)
        }
        guard decision != .continueRecording else { return }

        owLog("[VoiceAutoStop] \(decision) — \(detector.summary)")
        voiceEndpointDetector = nil
        ownVoiceStopGate = nil
        switch decision {
        case .stop, .stopMaxDuration:
            // No release tail: the speaker has already been quiet for `silenceToStop`.
            hotkey?.externalCancelHandsFree()
            stopRecording()
        case .cancelNoSpeech:
            hotkey?.externalCancelHandsFree()
            discardActiveRecording(reason: "voice trigger, no speech")
        case .continueRecording:
            break
        }
    }

    /// Scores the last 1.5 s against the enrolled voice (one check at a time, every 0.5 s) and
    /// stops the session once the user's voice has gone missing, whoever else is still talking.
    private func checkOwnVoiceEndpoint() {
        guard recordingState == .recording, ownVoiceStopGate != nil, !ownVoiceCheckInFlight,
              let profile = targetSpeakerProfile, let audioEngine else { return }
        let now = CACurrentMediaTime()
        guard now - lastOwnVoiceCheck >= OwnVoiceStopGate.checkInterval else { return }
        let samples = audioEngine.recentSamples(count: OwnVoiceStopGate.windowSamples)
        guard samples.count >= OwnVoiceStopGate.windowSamples else { return }
        lastOwnVoiceCheck = now
        ownVoiceCheckInFlight = true
        let filter = targetSpeakerFilter
        let sessionID = activeTranscriptionSession?.id
        Task { [weak self] in
            let score: Float?
            do {
                score = try await filter.wakeSpeakerScore(samples: samples, profile: profile)
            } catch {
                owLog("[OwnVoiceStop] Speaker check failed, disarming: \(error)")
                score = nil
            }
            guard let self else { return }
            self.ownVoiceCheckInFlight = false
            guard self.recordingState == .recording, self.activeTranscriptionSession?.id == sessionID,
                  var gate = self.ownVoiceStopGate else { return }
            guard let score else {
                self.ownVoiceStopGate = nil
                return
            }
            let shouldStop = gate.record(score: score, at: now)
            self.ownVoiceStopGate = gate
            owLog(String(format: "[OwnVoiceStop] score %.3f (threshold %.2f)%@", score, gate.threshold,
                         shouldStop ? " — user's voice gone, stopping" : ""))
            guard shouldStop else { return }
            self.voiceEndpointDetector = nil
            self.ownVoiceStopGate = nil
            self.hotkey?.externalCancelHandsFree()
            self.stopRecording()
        }
    }

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
    /// With Bluetooth buds as the default input, automatic mode records from the buds' own mic
    /// by UID (close to the mouth, see `VoiceEndpointDetector.Config.closeTalk`); the wake word
    /// listener stays on the built-in mic so the buds only enter call mode while recording.
    var resolvedInputDeviceUID: String? {
        guard let inputDeviceUID else {
            return AudioEngine.systemDefaultBluetoothInput()?.uid
        }
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

    /// Cleanup counts as available only when the selected model is actually installed, not
    /// merely when Ollama is running. When it is, the model is loaded in the background so the
    /// first dictation doesn't wait on the cold load.
    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
        let model = ollamaModel
        cleanupAvailable = ollamaAvailable ? await LLMCleanup.isModelInstalled(model) : false
        if cleanupAvailable && llmCleanupEnabled {
            Task.detached(priority: .utility) { await LLMCleanup.warmUp(model: model) }
        }
    }
}
