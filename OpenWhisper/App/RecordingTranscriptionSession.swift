import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

/// Owns the audio/transcript state for one dictation. A new recording gets a new session so a
/// later Fn press cannot reset or append to a dictation that is still being transcribed.
@MainActor
final class RecordingTranscriptionSession {
    let id: UInt64
    let startedAt = Date()
    let latency = VoiceLatencyTracker()
    let targetApp: NSRunningApplication?
    var pasteContext: PasteContext
    let stream: AsyncStream<CompletedAudioSegment>
    let continuation: AsyncStream<CompletedAudioSegment>.Continuation
    let targetSpeakerEnabled: Bool
    let targetSpeakerProfile: TargetSpeakerProfile?
    /// The mic `targetSpeakerProfile` belongs to, so a confirmed sample grows that profile.
    var targetSpeakerMic: TargetSpeakerMic = .mac
    /// Started by voice ("Jarvis", Vocal Shortcuts, openwhisper://start) rather than Fn:
    /// the user is giving a command, so Spotify intents are read less strictly.
    var bypassAudioProcessing = false
    var isVoiceCommand = false
    /// How the recording was started; upgraded to `.fnSpace` when Space locks a Fn hold.
    var trigger: RecordingTrigger = .fnHold
    /// The Mac was playing media during the recording: audio the profile rejects is then most
    /// likely the speakers, and is never transcribed or offered back (see the salvage path).
    var mediaWasPlaying = false
    /// Whether this recording ran echo cancellation; then `playbackHeard` (set by the canceller
    /// when the speakers actually carried sound) decides instead of `mediaWasPlaying`, which stays
    /// true while Safari merely has a paused video open.
    var echoCancelled = false
    var playbackHeard = OSAllocatedUnfairLock(initialState: false)
    /// Buds sessions: media is paused before their mic goes live, so a rejected batch is the user
    /// or someone nearby, never the Mac, unless the pause left something playing in the ear.
    var playbackSurvivedPause: (() -> Bool)?
    var speakersPlayed: Bool {
        if let playbackSurvivedPause { return mediaWasPlaying && playbackSurvivedPause() }
        return echoCancelled ? playbackHeard.withLock { $0 } : mediaWasPlaying
    }
    /// Commands (system, Spotify, reminders, "… bunu yaz") run for voice sessions and for the
    /// dictation keys (Fn, Fn+Space, the recording shortcut) alike. Chat, the first-sentence
    /// split and spoken replies stay voice-only: at the keyboard a non-command is typed.
    /// A `.followUp` opened after a command: only a command is taken from it, and a bare
    /// "sonrakine geç" is read against this domain (`CommandFollowUp`).
    var followsCommand = false
    /// A weak wake Whisper didn't confirm: kept open anyway; with media playing at the start
    /// only a command is taken from it (the call may have come from the video).
    var wakeUnconfirmed = false
    /// Text of batches the profile rejected while the speakers played, in a called-Jarvis
    /// session. Over a song or video the user's own windows score 0.05–0.28, no higher than the
    /// residual (17 Oct 2026: "Saat kaç?", "Video durdur" after a 0.99 wake, all dropped
    /// unheard), so the profile cannot tell them apart; the words can. Used only when no batch
    /// matched, and then only for a command (`heardOnlyOverPlayback`).
    var playbackCommandTexts: [String] = []
    /// The text came from `playbackCommandTexts`: never typed, chatted, shown or offered.
    var heardOnlyOverPlayback = false
    /// Only a command is taken from this session, never dictation or chat.
    var takesOnlyCommands: Bool {
        followsCommand || wakeUnconfirmed && mediaWasPlaying || heardOnlyOverPlayback
    }
    var commandFollowUpDomain: CommandFollowUp.Domain?
    /// A `.followUp` opened after a Claude / Codex recap: the transcript is sent to that chat.
    var sendsToRecappedSession: AgentApp?
    /// Jarvis's reply that was playing when this follow-up opened; its echo is cut from the text.
    var precedingReply: String?
    var acceptsCommands: Bool {
        isVoiceCommand || [.fnHold, .fnSpace, .keyboardShortcut].contains(trigger)
    }
    /// The speech fixes and checks (length, sound-alikes, repetition, foreign words) are for
    /// transcripts; typed text is taken as written.
    var appliesSpeechChecks: Bool { trigger != .typed }

    /// Keyboard focus the router decides by. A typed request was written to Jarvis, so a
    /// non-command is answered, never pasted into the field behind the panel.
    static func routingFocus(trigger: RecordingTrigger, captured: TextFocusStatus,
                             simulated: TextFocusStatus?) -> TextFocusStatus {
        trigger == .typed ? .notEditable : simulated ?? captured
    }

    var routingFocus: TextFocusStatus {
        Self.routingFocus(trigger: trigger, captured: pasteContext.focusStatus,
                          simulated: VoiceTestInjector.shared.simulatedFocus)
    }

    // Session-scoped so an old decode can never stop a newer microphone session.
    var doneCheckInFlight = false
    var doneLastSpeechTime: TimeInterval = 0
    var doneCheckedSpeechTime: TimeInterval = 0
    var doneLastCheckTime: TimeInterval = 0
    var doneCheckedEndpointTime: TimeInterval = 0
    var overReplyLastCheckTime: TimeInterval = 0
    var speechPreview: SpeechPreview?
    var previewEndpointDetector: SmartTurnEndpointDetector?

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
    /// Per batch: own-voice vs other-voice words and levels, for the recording's trace header.
    var speakerBatches: [SpeakerBatchLog] = []
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
    /// Every transcription of a deletion-confirmation answer, including the unmasked one,
    /// so the judge sees "Olaylıyorum" even when the masked re-decode says "Ona iliyorum".
    var heardVariants: [String] = []
    var hadSingleSpeakerUncertain = false
    /// The "Jarvis" that started this session already matched the user's voice. A recording
    /// with one coherent speaker is then the user, even if its absolute score is borderline.
    var wakeSpeakerVerified = false
    /// The `WakeClipLog` record of the "Jarvis" that started this session.
    var wakeClipID: UUID?
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
