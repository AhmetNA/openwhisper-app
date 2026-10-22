import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

@Observable
@MainActor
final class AppState {

    static let shared = AppState()

    let recordingHistoryStore = RecordingHistoryStore()
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
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            if damgaEnabled && language == "tr" {
                Task { await DamgaNormalizer.shared.prepare() }
            } else {
                DamgaNormalizer.shared.stop()
            }
        }
    }
    /// The chain speaker profiles are keyed to; `deepFilterSetting` drives it, and each
    /// recording's actual mode comes from `deepFilterAuto` (see `startRecording`).
    var audioProcessingMode: AudioProcessingMode {
        didSet { UserDefaults.standard.set(audioProcessingMode.rawValue, forKey: "audioProcessingMode") }
    }
    var deepFilterSetting: DeepFilterSetting {
        didSet {
            UserDefaults.standard.set(deepFilterSetting.rawValue, forKey: "deepFilterSetting")
            audioProcessingMode = deepFilterSetting.profileMode
        }
    }
    @ObservationIgnored var deepFilterAuto = DeepFilterAutoDecider()
    var llmCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(llmCleanupEnabled, forKey: "llmCleanupEnabled") }
    }
    /// Opt-in final-output formatting, independent of Ollama cleanup.
    var damgaEnabled: Bool {
        didSet {
            UserDefaults.standard.set(damgaEnabled, forKey: "damgaEnabled")
            if damgaEnabled && language == "tr" {
                Task { await DamgaNormalizer.shared.prepare() }
            } else {
                DamgaNormalizer.shared.stop()
            }
        }
    }
    /// Jarvis answers voice commands out loud (`JarvisVoice`, with the provider below).
    var voiceRepliesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceRepliesEnabled, forKey: "voiceRepliesEnabled")
            if voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }
        }
    }
    /// "Dilayım'dan mesaj var, okuyayım mı?" when someone writes on WhatsApp (`WhatsAppWatcher`).
    var whatsAppAnnouncementsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(whatsAppAnnouncementsEnabled, forKey: "whatsAppAnnouncementsEnabled")
            if whatsAppAnnouncementsEnabled { whatsAppWatcher.start() } else { whatsAppWatcher.stop() }
        }
    }
    /// Who makes the voice (`SpeechProviders.all`): only how a reply sounds, never what it says.
    var voiceProviderID: String {
        didSet {
            guard voiceProviderID != oldValue else { return }
            SpeechSettingsStore.standard.providerID = voiceProviderID
            voiceModelID = SpeechSettingsStore.standard.modelID(for: voiceProviderID)
            voiceID = SpeechSettingsStore.standard.voiceID(for: voiceProviderID)
            applyVoiceProvider()
        }
    }
    /// Model of `voiceProviderID`; each provider remembers its own.
    var voiceModelID: String {
        didSet {
            guard voiceModelID != oldValue else { return }
            SpeechSettingsStore.standard.setModelID(voiceModelID, for: voiceProviderID)
            applyVoiceProvider()
        }
    }

    /// Voice of `voiceProviderID` ("" when it has no choice); each provider remembers its own.
    var voiceID: String {
        didSet {
            guard voiceID != oldValue else { return }
            SpeechSettingsStore.standard.setVoiceID(voiceID, for: voiceProviderID)
            applyVoiceProvider()
        }
    }

    /// Who makes the classification decisions (Spotify intent, wake-word check, "talking to
    /// Jarvis?"): Ollama, or the local SetFit models with Ollama as the fallback (`SetFitDecider`).
    var decisionEngine: SetFitDecider.Engine {
        didSet {
            UserDefaults.standard.set(decisionEngine.rawValue, forKey: SetFitDecider.defaultsKey)
            applyDecisionEngine()
        }
    }
    /// Settings shows this under the engine picker.
    var setFitStatus = "Kapalı"

    @ObservationIgnored var jarvisReply = JarvisReply()
    /// "Dilayım'a yaz: …": the draft waiting for "evet" / "hayır".
    @ObservationIgnored let whatsAppWatcher = WhatsAppWatcher()
    /// Chats that wrote while the screen was locked (`announceMissedWhatsApp`).
    @ObservationIgnored var missedWhatsAppChats: [Int64] = []
    @ObservationIgnored lazy var whatsAppSender = WhatsAppSender(pressReturn: { pid in TextInjector().pressReturn(inPID: pid) })
    /// "Test modunu başlat": the TODO.md item being tried now.
    @ObservationIgnored let voiceTest = VoiceTestSession()
    /// The last thing Jarvis said, for "ne dedin?".
    @ObservationIgnored var lastSpokenReply: String?
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
            JarvisVoice.shared.translationModel = ollamaModel
            if oldValue != ollamaModel {
                let previous = oldValue
                Task.detached(priority: .utility) { await LLMCleanup.unload(model: previous) }
            }
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
            && !VoiceTestInjector.shared.bypassesSpeakerChecks
    }
    /// "Jarvis" wakes only for the enrolled voice, checked against the profile of the mic the
    /// wake listener hears through (none for that mic: the check is off).
    var targetSpeakerGuardsWakeWord: Bool {
        targetSpeakerEnabled && targetSpeakerScope.coversWakeWord && wakeTargetSpeakerProfile != nil
            && !VoiceTestInjector.shared.bypassesSpeakerChecks
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
    /// The user's mic order (see `MicPriority`); every recording uses the highest-ranked
    /// connected mic. Unplugged mics keep their place for three days.
    var inputPriority: [MicPriorityEntry] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(inputPriority) {
                UserDefaults.standard.set(data, forKey: MicPriority.defaultsKey)
            }
            guard oldValue.map(\.uid) != inputPriority.map(\.uid) else { return }
            owLog("[Input] Mic priority: \(inputPriority.map(\.name).joined(separator: " > "))")
            syncWakeWordInput()
        }
    }
    var inputPriorityUIDs: [String] { inputPriority.map(\.uid) }
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

    var audioLevel: Float = 0.0
    /// False from the start of a Bluetooth recording until the buds' mic delivers real audio
    /// (their call-mode link takes ~0.25–0.75 s). The flow bar says "connecting" until then.
    var recordingInputReady = true
    /// The input of the last session that was not itself a confirmation or follow-up, so the
    /// confirmation or follow-up it leads to records from the same mic.
    var chainedInputUID: String?
    var recordingIgnoredLeadingSeconds: TimeInterval = 0
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
    var microphoneGranted: Bool = false {
        didSet { updateWakeWordListener() }
    }
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

    /// The buds' own profile, enrolled through their call-mode mic. Buds recordings are filtered
    /// against it; without it they are not filtered at all (the Mac profile rejects them).
    var budsTargetSpeakerProfile: TargetSpeakerProfile?
    var budsTargetSpeakerProfileStatus: String = "Henüz kayıt yok"
    var hasStoredBudsTargetSpeakerProfile = false
    var hasBudsTargetSpeakerProfile: Bool {
        budsTargetSpeakerProfile?.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) == true
    }
    /// The external (USB, wired) mic's own profile, kept like the buds one: without it recordings
    /// from such a mic are not filtered at all.
    var externalTargetSpeakerProfile: TargetSpeakerProfile?
    var externalTargetSpeakerProfileStatus: String = "Henüz kayıt yok"
    var hasStoredExternalTargetSpeakerProfile = false
    var hasExternalTargetSpeakerProfile: Bool {
        externalTargetSpeakerProfile?.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) == true
    }
    /// The mic the running enrollment builds a profile for.
    var targetSpeakerEnrollmentMic: TargetSpeakerMic = .mac
    /// The profile the on-demand sample is appended to, fixed when it starts.
    var targetSpeakerSampleMic: TargetSpeakerMic = .mac
    /// The profile the retained "Bu benim sesimdi" candidate belongs to.
    var retainedConfirmationMic: TargetSpeakerMic = .mac
    /// The profile `lastConfirmedAppendReceipt` was written to.
    var lastConfirmedAppendMic: TargetSpeakerMic = .mac

    // MARK: - Components

    var audioEngine: AudioEngine?
    let transcriptionModelRegistry = TranscriptionModelRegistry()
    var llmCleanup: LLMCleanup?
    /// Bumped for every transcript: a background correction only acts if no newer
    /// transcript came in meanwhile.
    var correctionGeneration: UInt64 = 0
    var textInjector: TextInjecting? = TextInjector()
    var hotkey: GlobalHotkey?
    var flowBarController: FlowBarController?
    var reminderManager: ReminderManager?
    var recordingTimer: Timer?
    var targetApp: NSRunningApplication?
    let targetSpeakerProfileStore: TargetSpeakerProfileStore
    let budsTargetSpeakerProfileStore: TargetSpeakerProfileStore
    let externalTargetSpeakerProfileStore: TargetSpeakerProfileStore
    let targetSpeakerModel: TargetSpeakerModelProvider
    let targetSpeakerFilter: TargetSpeakerFilter
    let targetSpeakerDiarization: TargetSpeakerDiarizationService
    let injectedTranscriptionService: WhisperTranscriptionService?
    var targetSpeakerProfile: TargetSpeakerProfile?
    var targetSpeakerEnrollmentTask: Task<Void, Never>?
    var targetSpeakerDiarizationPreparationTask: Task<Void, Never>?
    var targetSpeakerDiarizationReady = false
    var targetSpeakerEnrollmentGeneration: UInt64 = 0
    var targetSpeakerEnrollmentRecordings: [[Float]] = []
    /// Both recordings of an enrollment the quality check turned down, and the score it measured,
    /// so Settings can offer to accept the profile as is.
    var targetSpeakerRejectedEnrollment: TargetSpeakerRejectedEnrollment?
    /// Per mic (`TargetSpeakerMic.rawValue`), the score of a profile accepted below the quality
    /// check; Settings warns that it may match poorly.
    var targetSpeakerLowScores: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "targetSpeakerLowScores") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(targetSpeakerLowScores, forKey: "targetSpeakerLowScores") }
    }
    var flowBarMessageTask: Task<Void, Never>?
    var targetSpeakerAppendOfferTask: Task<Void, Never>?
    /// The exact coherent candidate, transcript, and target captured for the 8-second explicit
    /// confirmation offer. These three values are cleared together on timeout, next recording,
    /// or tap; no rejected/overlap audio is substituted into this path.
    var retainedConfirmationCandidate: TargetSpeakerConfirmationCandidate?
    var retainedConfirmationText: String?
    var retainedConfirmationPasteContext: PasteContext?
    var retainedConfirmationTargetApp: NSRunningApplication?
    var confirmationOperationID: UInt64 = 0
    var isConfirmationInFlight = false
    var confirmationPasteOutcome: PasteOutcome?
    var confirmationPasteCompleted = false
    var confirmationAppendCompleted = false
    var confirmationAppendSucceeded = false
    var confirmationAppendError: String?
    var confirmationTextBeingDelivered = ""
    var lastConfirmedAppendReceipt: TargetSpeakerProfileAppendReceipt?
    var activeTranscriptionSession: RecordingTranscriptionSession?
    /// Sessions are transcribed in order, while the microphone can start the next session as
    /// soon as the previous one is stopped.
    var transcriptionQueueTail: Task<Void, Never>?
    var transcriptionQueueTailID: UInt64?
    var nextTranscriptionID: UInt64 = 0
    var pendingTranscriptionCount = 0
    var delayedStopWorkItem: DispatchWorkItem?
    /// Menu bar switch for the own "Jarvis" listener.
    var wakeWordEnabled = UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled")
            updateWakeWordListener()
            updateRemoteControl()
        }
    }
    /// Settings › Jarvis: keeps the Mac awake and "Jarvis" listening while the display sleeps.
    var remoteControlEnabled = UserDefaults.standard.bool(forKey: "remoteControlEnabled") {
        didSet {
            UserDefaults.standard.set(remoteControlEnabled, forKey: "remoteControlEnabled")
            updateRemoteControl()
        }
    }
    @ObservationIgnored let remoteControl = RemoteControl()
    /// `updateDisplayAsleepWork` has slowed the display-only work down.
    @ObservationIgnored var displayAsleepWorkReduced = false
    /// Settings › Jarvis: a key that starts the same session as "Hey Jarvis" (nil = not set).
    var jarvisHotkey: JarvisHotkey? = JarvisHotkey.load() {
        didSet {
            JarvisHotkey.save(jarvisHotkey)
            if !jarvisHotkeyCapturing { hotkey?.jarvisKey = jarvisHotkey }
        }
    }
    /// Settings › Jarvis: the shortcut that opens the "write to Jarvis" panel (default ⌃M).
    var typedRequestHotkey: JarvisHotkey? = JarvisHotkey.loadTypedRequest() {
        didSet {
            JarvisHotkey.saveTypedRequest(typedRequestHotkey)
            if !jarvisHotkeyCapturing { hotkey?.typedRequestKey = typedRequestHotkey }
        }
    }
    /// While Settings records a new Jarvis key or typed request shortcut both are unbound, so
    /// pressing one there doesn't start a session or open the panel.
    var jarvisHotkeyCapturing = false {
        didSet {
            hotkey?.jarvisKey = jarvisHotkeyCapturing ? nil : jarvisHotkey
            hotkey?.typedRequestKey = jarvisHotkeyCapturing ? nil : typedRequestHotkey
            hotkey?.fnSuppressed = jarvisHotkeyCapturing
        }
    }
    @ObservationIgnored var typedRequestPanel: TypedRequestPanelController?
    /// The app frontmost when the panel opened, and its focus read in the background.
    @ObservationIgnored var typedRequestTargetApp: NSRunningApplication?
    @ObservationIgnored var typedRequestPasteContext: Task<PasteContext, Never>?
    /// A media/brightness key pressed while Settings records the Jarvis key: macOS keeps it
    /// for itself (no keyDown), so the recorder explains why it can't be bound.
    var jarvisCaptureSystemKey: JarvisHotkey.SystemKeyPress?
    var wakeWordListening = false
    var wakeWordStatus = "Kapalı"
    /// Enabled but can't hear "Jarvis" for a reason the user can fix: the menu bar icon
    /// and the status line turn orange so it's visible without opening the log.
    var wakeWordBlocked = false
    @ObservationIgnored var wakeWordListener: WakeWordListener?
    @ObservationIgnored var wakeCandidateVerifying = false
    /// Bumped per weak direct detection so a late verdict never discards a newer session.
    @ObservationIgnored var wakeConfirmationID = 0
    /// The wake speaker check finished before the session it belongs to was created.
    @ObservationIgnored var pendingWakeSpeakerVerified = false
    /// Back-to-back reply follow-ups; capped so echo or a TV can't keep Jarvis listening.
    @ObservationIgnored var replyFollowUpChain = 0
    /// After Jarvis asks something back, how long the mic waits for the first word.
    nonisolated static let replyFollowUpWindow: TimeInterval = 2.5
    /// Leading part of that window ignored as Jarvis's own voice tail.
    nonisolated static let replyFollowUpEchoGuard: TimeInterval = 0.4
    nonisolated static let maxReplyFollowUps = 2
    /// The next `.followUp` recording comes after a command (`listenAfterCommand`): the
    /// command's domain, nil inside when "sonraki" means nothing there. Consumed at the start.
    @ObservationIgnored var pendingCommandFollowUp: CommandFollowUp.Domain??
    /// Back-to-back command follow-ups ("sonrakine geç", again and again).
    @ObservationIgnored var commandFollowUpChain = 0
    /// After a command, how long the mic waits for a fix ("sonrakine geç").
    nonisolated static let commandFollowUpWindow: TimeInterval = 2
    nonisolated static let maxCommandFollowUps = 3
    /// A weak wake rejected by Whisper still keeps its session open this long before closing.
    nonisolated static let minimumRejectedWakeOpen: TimeInterval = 1
    /// Longest a command follow-up recording may run once something was heard.
    nonisolated static let commandFollowUpMaxDuration: TimeInterval = 6
    /// The next command follow-up opens as Jarvis starts his reply, not after it.
    @ObservationIgnored var commandFollowUpOverReply = false
    /// That follow-up is recording while the reply plays: its window starts when the reply ends.
    @ObservationIgnored var commandFollowUpAwaitingReplyEnd = false
    /// Wake clip waiting for the session it started (handed over like `pendingWakeSpeakerVerified`).
    @ObservationIgnored var pendingWakeClipID: UUID?
    @ObservationIgnored var mediaActivityMonitor: SystemMediaActivityMonitor?
    @ObservationIgnored var mediaPlaying = false
    @ObservationIgnored var systemAsleep = false
    @ObservationIgnored var screensAsleep = false
    @ObservationIgnored var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored let recordingMedia = RecordingMediaController.shared
    /// Set by a URL start just before it reaches `startRecording()`, consumed there.
    @ObservationIgnored var armVoiceAutoStopForNextRecording = false
    /// Present only for voice-triggered sessions; ends them after the speaker goes quiet.
    @ObservationIgnored var voiceEndpointDetector: VoiceEndpointDetector?
    /// The mic the running recording captures from, to end it if that mic is unplugged.
    @ObservationIgnored var activeRecordingInputUID: String?
    /// Model-based endpointing for Jarvis sessions. The level detector above remains only as a
    /// fail-open fallback when either local model is unavailable.
    @ObservationIgnored var smartTurnEndpointDetector: SmartTurnEndpointDetector?
    @ObservationIgnored var lastVoiceEndpointTrace: TimeInterval = 0
    /// Wake-word sessions with an enrolled voice: ends them when the user stops, even while
    /// someone else keeps talking. See `OwnVoiceStopGate`.
    @ObservationIgnored var ownVoiceStopGate: OwnVoiceStopGate?
    @ObservationIgnored var ownVoiceCheckInFlight = false
    @ObservationIgnored var lastOwnVoiceCheck: TimeInterval = 0
    var systemAudioCapture: SystemAudioCapture?
    var systemAudioGeneration: UInt64 = 0
    var systemAudioTranscriptionTail: Task<Void, Never>?
    var recordingPreviewTask: Task<Void, Never>?

    /// Whether any background transcription task (other than the currently recording session) is running.
    var isTranscribing: Bool {
        activeTranscriptionSession != nil ? pendingTranscriptionCount > 1 : pendingTranscriptionCount > 0
    }

    // MARK: - Output Swap State

    /// The raw Whisper transcript and LLM-cleaned text from the most recently completed
    /// (and actually pasted) dictation, kept around so Option+Z can swap between them.
    struct DictationPair {
        let raw: String
        let cleaned: String
    }
    var swapPair: DictationPair?
    /// Which version is currently sitting at the cursor.
    var lastInjectedIsCleaned: Bool = true
    /// The exact string currently injected (post-trim, matching what TextInjector actually
    /// pasted) — its `count` drives how many backspaces a swap sends.
    var lastInjectedText: String = ""
    /// The target belonging to the latest raw/cleaned pair, not necessarily the app from the
    /// most recently started recording.
    var swapTargetApp: NSRunningApplication?
    /// AX baseline for the latest injected span, retained so cleanup/swap can update a
    /// background target without reactivating it.
    var swapPasteContext: PasteContext?

    // MARK: - Computed

    var menuBarIcon: String {
        switch recordingState {
        case .idle: systemAudioEnabled ? "speaker.wave.2.fill" : wakeWordBlocked ? "mic.badge.xmark" : "mic.fill"
        case .recording: "waveform"
        case .transcribing: "waveform.path.ecg"
        }
    }

    var menuBarIconColor: Color {
        switch recordingState {
        case .idle: systemAudioIsRecording ? .red : wakeWordBlocked ? .orange : .white
        case .recording: .red
        case .transcribing: .orange
        }
    }

    // MARK: - Init

    init(
        profileStore: TargetSpeakerProfileStore = KeychainTargetSpeakerProfileStore(),
        budsProfileStore: TargetSpeakerProfileStore? = nil,
        externalProfileStore: TargetSpeakerProfileStore? = nil,
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
        if let raw = defaults.string(forKey: "deepFilterSetting"), let setting = DeepFilterSetting(rawValue: raw) {
            deepFilterSetting = setting
        } else {
            // The old manual switch: DeepFilter becomes Otomatik, an explicit "Engelsiz" stays off.
            let storedMode = defaults.string(forKey: "audioProcessingMode") ?? ""
            let migrated: DeepFilterSetting = storedMode == AudioProcessingMode.deepFilterNet.rawValue ? .automatic : .off
            deepFilterSetting = migrated
            defaults.set(migrated.rawValue, forKey: "deepFilterSetting")
            owLog("[DeepFilterAuto] Setting migrated from audioProcessingMode=\(storedMode) to \(migrated.rawValue)")
        }
        llmCleanupEnabled = defaults.object(forKey: "llmCleanupEnabled") as? Bool ?? true
        damgaEnabled = defaults.object(forKey: "damgaEnabled") as? Bool ?? false
        laughterToRandomEnabled = defaults.object(forKey: "laughterToRandomEnabled") as? Bool ?? false
        voiceRepliesEnabled = defaults.object(forKey: "voiceRepliesEnabled") as? Bool ?? true
        whatsAppAnnouncementsEnabled = defaults.object(forKey: "whatsAppAnnouncementsEnabled") as? Bool ?? true
        voiceProviderID = SpeechSettingsStore.standard.providerID
        voiceModelID = SpeechSettingsStore.standard.modelID(for: SpeechSettingsStore.standard.providerID)
        voiceID = SpeechSettingsStore.standard.voiceID(for: SpeechSettingsStore.standard.providerID)
        decisionEngine = defaults.string(forKey: SetFitDecider.defaultsKey).flatMap(SetFitDecider.Engine.init(rawValue:)) ?? .defaultEngine
        let savedModel = defaults.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
        // Models dropped from the picker (the ByT5 normalizer, llama3.2:3b) fall back to the default
        // instead of leaving a selection Settings can't show.
        let isSupported = LLMCleanup.supportedModels.contains { $0.tag == savedModel }
        let model = isSupported ? savedModel : LLMCleanup.defaultModel
        ollamaModel = model
        JarvisVoice.shared.translationModel = model
        flowBarEnabled = defaults.object(forKey: "flowBarEnabled") as? Bool ?? true
        autoPasteEnabled = defaults.object(forKey: "autoPasteEnabled") as? Bool ?? true
        targetSpeakerEnabled = defaults.object(forKey: "targetSpeakerEnabled") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        inputPriority = Self.loadInputPriority(defaults)
        audioDuckingEnabled = defaults.object(forKey: "audioDuckingEnabled") as? Bool ?? true
        targetSpeakerProfileStore = profileStore
        // Tests pass an in-memory Mac store; never let them reach the real Keychain buds item.
        budsTargetSpeakerProfileStore = budsProfileStore
            ?? (profileStore is KeychainTargetSpeakerProfileStore
                ? KeychainTargetSpeakerProfileStore(mic: .buds) : InMemoryTargetSpeakerProfileStore())
        externalTargetSpeakerProfileStore = externalProfileStore
            ?? (profileStore is KeychainTargetSpeakerProfileStore
                ? KeychainTargetSpeakerProfileStore(mic: .external) : InMemoryTargetSpeakerProfileStore())
        self.targetSpeakerModel = targetSpeakerModel
        targetSpeakerFilter = TargetSpeakerFilter(model: targetSpeakerModel)
        self.targetSpeakerDiarization = targetSpeakerDiarization
        injectedTranscriptionService = transcriptionService
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
    }

    static let targetSpeakerEnrollmentPromptText =
        "Oturur pozisyonda doğal biçimde konuş."

    static let targetSpeakerEnrollmentConditionPrompts = [
        "Oturur pozisyonda doğal biçimde konuş.",
        "Şimdi pozisyonunu değiştirip, mümkünse yatarak doğal biçimde konuş."
    ]

    // MARK: - Setup

    var activeTranscriptionService: WhisperTranscriptionService? {
        if let injectedTranscriptionService {
            return injectedTranscriptionService
        }
        return transcriptionModelRegistry.provider(for: transcriptionModel)
    }

    // MARK: - On-demand target speaker sample capture

    var isSwapping: Bool = false

    // MARK: - Wake word

    /// The mic the next recording uses, see `resolvedInputDeviceUID(for:)`.
    var resolvedInputDeviceUID: String? {
        resolvedInputDeviceUID(for: nil)
    }

    var resolvedInputIsBluetooth: Bool {
        Self.inputIsBluetooth(uid: resolvedInputDeviceUID)
    }

}
