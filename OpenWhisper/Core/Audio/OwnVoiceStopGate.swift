import Foundation

/// Ends a wake-word session when someone *else* is talking after the user has stopped.
///
/// `VoiceEndpointDetector` and Smart Turn only hear a voice, so a friend talking next to the Mac
/// keeps the recording open. With "Yalnızca Benim Sesim" enrolled, the last 1.5 s of audio is
/// scored against the profile every half second.
///
/// The gate only answers "whose voice is this?", never "has the talking stopped?" — that is
/// Smart Turn's job. The first version ended the session after 3 s without a score ≥ 0.40 and
/// cut the user mid-sentence (15 cuts on 27 Sep 2026): silent windows score 0.08–0.18, and the
/// user's own live speech hovers at 0.30–0.40, below the wake-word threshold. So now:
/// - windows without enough speech in them are ignored (neither a match nor a miss);
/// - anything at or above `userThreshold` counts as the user and resets the count;
/// - only `consecutiveMissesToStop` speech windows in a row below `otherThreshold` stop it.
///   Scores in between are ambiguous and change nothing.
/// Replaying the 27 Sep log (1 Hz level traces) with these values stops none of the 15 sessions;
/// 3 windows at 0.20 did too, while 2 at 0.20 or 3 at 0.25 wrongly stopped 1–2.
///
/// Fail-open: until the user's voice has matched once, the gate never stops anything.
///
/// With the Mac playing a video or song (`watchesPlayback`) it is armed even when the filter is
/// off, because what the echo canceller leaves of the speakers is "a voice" to Silero: 20+ s
/// sessions never closed after the user stopped (16 Oct 2026, ERLE 5–13 dB). The video's
/// residual scored 0.29 against the profile, inside the ambiguous band, so two more rules
/// decide on the user's voice alone: `endsTurnOverPlayback` after Smart Turn's pause, and
/// `noUserVoiceLimit` without one.
struct OwnVoiceStopGate {
    /// Score window: the speaker model's minimum input (1.5 s at 16 kHz).
    static let windowSamples = TargetSpeakerFilterConfiguration.speakerWindowSamples
    static let windowDuration = Double(windowSamples) / 16_000
    static let checkInterval: TimeInterval = 0.5

    var userThreshold: Float = 0.30
    var otherThreshold: Float = 0.20
    /// Four windows 0.5 s apart: about 2 s of clearly foreign speech.
    var consecutiveMissesToStop = 4
    /// Loud time a window needs before its score says anything about who is talking.
    var minSpeechInWindow: TimeInterval = 0.4

    /// Playback mode: with this long of speech windows and none of them the user's, the session ends.
    var noUserVoiceLimit: TimeInterval = 5
    /// A user match counts as speaking again after a pause only when its window lies mostly after it.
    static let resumeMargin: TimeInterval = 0.75
    /// Over playback the pause after the turn waits this much longer than Smart Turn's own.
    static let playbackSilenceExtra: TimeInterval = 1
    /// Smart Turn's `minimumListenDuration`: a wake word and a pause must not end the session.
    static let minimumListenDuration: TimeInterval = 4

    enum Verdict: Equatable {
        case keep
        /// Someone else has been talking for about 2 s after the user.
        case otherVoice
        /// Playback mode: `noUserVoiceLimit` of speech without the user in it.
        case noUserVoice
    }

    let startTime: TimeInterval
    let watchesPlayback: Bool
    private(set) var userHeard = false
    /// End of the last window that scored as the user.
    private(set) var lastUserMatch: TimeInterval?
    private var misses = 0
    /// Level frames above the room floor by the onset margin, kept for one scoring window.
    private var loudFrames: [(time: TimeInterval, duration: TimeInterval)] = []
    private var lastLevelTime: TimeInterval?

    init(startTime: TimeInterval = 0, watchesPlayback: Bool = false) {
        self.startTime = startTime
        self.watchesPlayback = watchesPlayback
    }

    /// Feed every level frame. `loud`: speech-level relative to the room floor (anyone's voice).
    mutating func noteLevel(loud: Bool, at time: TimeInterval) {
        let dt = min(max(time - (lastLevelTime ?? time), 0), 0.2)
        lastLevelTime = time
        if loud { loudFrames.append((time, dt)) }
        loudFrames.removeAll { time - $0.time > Self.windowDuration + 0.5 }
    }

    func speechDuration(endingAt time: TimeInterval) -> TimeInterval {
        loudFrames.filter { $0.time <= time && time - $0.time <= Self.windowDuration }
            .reduce(0) { $0 + $1.duration }
    }

    /// `time`: when the scored window ended.
    mutating func record(score: Float, at time: TimeInterval) -> Verdict {
        guard speechDuration(endingAt: time) >= minSpeechInWindow else { return .keep }
        if score >= userThreshold {
            userHeard = true
            lastUserMatch = time
            misses = 0
            return .keep
        }
        if watchesPlayback, time - (lastUserMatch ?? startTime) >= noUserVoiceLimit { return .noUserVoice }
        guard userHeard, score < otherThreshold else { return .keep }
        misses += 1
        return misses >= consecutiveMissesToStop ? .otherVoice : .keep
    }

    /// Playback mode: Smart Turn found a pause at `endpointAt` (its required silence for that
    /// verdict: `requiredSilence`), but the speakers' residual keeps Silero from ever hearing the
    /// silence. The turn is over unless the user's own voice came back after the pause.
    func endsTurnOverPlayback(endpointAt: TimeInterval, requiredSilence: TimeInterval, now: TimeInterval) -> Bool {
        guard watchesPlayback, now - startTime >= Self.minimumListenDuration else { return false }
        if let lastUserMatch, lastUserMatch >= endpointAt + Self.resumeMargin { return false }
        return now - endpointAt >= requiredSilence + Self.playbackSilenceExtra
    }
}
