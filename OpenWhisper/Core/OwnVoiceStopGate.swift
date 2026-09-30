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

    private(set) var userHeard = false
    private var misses = 0
    /// Level frames above the room floor by the onset margin, kept for one scoring window.
    private var loudFrames: [(time: TimeInterval, duration: TimeInterval)] = []
    private var lastLevelTime: TimeInterval?

    init() {}

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

    /// `time`: when the scored window ended. Returns true when the recording should stop.
    mutating func record(score: Float, at time: TimeInterval) -> Bool {
        guard speechDuration(endingAt: time) >= minSpeechInWindow else { return false }
        if score >= userThreshold {
            userHeard = true
            misses = 0
            return false
        }
        guard userHeard, score < otherThreshold else { return false }
        misses += 1
        return misses >= consecutiveMissesToStop
    }
}
