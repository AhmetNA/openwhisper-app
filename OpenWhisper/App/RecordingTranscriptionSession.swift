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
    /// Started by voice ("Jarvis", Vocal Shortcuts, openwhisper://start) rather than Fn:
    /// the user is giving a command, so Spotify intents are read less strictly.
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
    var speakersPlayed: Bool { echoCancelled ? playbackHeard.withLock { $0 } : mediaWasPlaying }
    /// Commands (system, Spotify, reminders, "… bunu yaz") run for voice sessions and for the
    /// dictation keys (Fn, Fn+Space, the recording shortcut) alike. Chat, the first-sentence
    /// split and spoken replies stay voice-only: at the keyboard a non-command is typed.
    /// A `.followUp` opened after a command: only a command is taken from it, and a bare
    /// "sonrakine geç" is read against this domain (`CommandFollowUp`).
    var followsCommand = false
    var commandFollowUpDomain: CommandFollowUp.Domain?
    var acceptsCommands: Bool {
        isVoiceCommand || [.fnHold, .fnSpace, .keyboardShortcut].contains(trigger)
    }

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
