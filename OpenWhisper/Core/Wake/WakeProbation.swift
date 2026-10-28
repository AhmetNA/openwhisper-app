import Foundation

/// A "Jarvis" heard over playing media whose voice didn't match the user's. Videos and songs
/// woke Jarvis and paused them (28 Oct 2026: "people die in Mexico" at wake score 0.95, voice
/// 0.21), so such a session pauses nothing and only turns the media down
/// (`RecordingMediaController.begin(holdingPause:)`) until the user's voice confirms it: the
/// wake clip's speaker check, or what follows scoring at the wake threshold (this window's own
/// checks or `checkLateWakeVoice`). Whisper hearing "Jarvis" doesn't count: a song says it too.
/// Without the voice by `window` the session is dropped.
///
/// A plain hard reject would have lost about 1 in 15 of the user's own calls over media that day
/// (voice 0.32–0.38 on the "Jarvis" clip); the command after it gets a second chance here.
struct WakeProbation {
    /// Matches `AppState.lateWakeVoiceWindow`, whose checks confirm it too.
    static let window: TimeInterval = 5
    static let checkInterval: TimeInterval = 0.5

    let startTime: TimeInterval
    /// The enrolled voice for the session's microphone.
    let profile: TargetSpeakerProfile
    private(set) var confirmed = false

    init(startTime: TimeInterval, profile: TargetSpeakerProfile) {
        self.startTime = startTime
        self.profile = profile
    }

    mutating func confirm() { confirmed = true }

    /// A window of the session's audio scored against `profile`. True when it confirms the wake.
    mutating func record(score: Float, threshold: Float) -> Bool {
        guard !confirmed, score >= threshold else { return false }
        confirmed = true
        return true
    }

    func expired(at now: TimeInterval) -> Bool {
        !confirmed && now - startTime >= Self.window
    }
}
