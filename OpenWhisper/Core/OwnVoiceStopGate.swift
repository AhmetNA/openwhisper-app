import Foundation

/// Ends a wake-word session once the *user* stops talking, even if someone nearby keeps going.
///
/// `VoiceEndpointDetector` only sees the level, so a friend talking next to the Mac keeps the
/// recording open. With "Yalnızca Benim Sesim" enrolled, the last 1.5 s of audio is scored
/// against the profile every half second; once the user's voice has been heard and then
/// missing for `silenceToStop`, the session ends regardless of what else the mic picks up.
///
/// Fail-open: until the user's voice has matched once, the gate never stops anything, so a
/// mic whose scores run low (buds vs. the built-in mic the profile came from) falls back to
/// the level-only detector instead of cutting every command.
struct OwnVoiceStopGate {
    /// Score window: the speaker model's minimum input (1.5 s at 16 kHz).
    static let windowSamples = TargetSpeakerFilterConfiguration.speakerWindowSamples
    static let checkInterval: TimeInterval = 0.5

    let threshold: Float
    /// Time since the last matching window before stopping. A window still holds 1.5 s of
    /// audio, so the perceived pause after the user's last word is roughly 2–2.5 s.
    var silenceToStop: TimeInterval = 1.5

    private(set) var lastMatchTime: TimeInterval?

    init(threshold: Float) {
        self.threshold = threshold
    }

    /// `time`: when the scored window ended. Returns true when the recording should stop.
    mutating func record(score: Float, at time: TimeInterval) -> Bool {
        if score >= threshold {
            lastMatchTime = time
            return false
        }
        guard let lastMatchTime else { return false }
        return time - lastMatchTime >= silenceToStop
    }

    /// Minimum score for a window to count as the user speaking.
    /// Override: `defaults write com.openwhisper.app targetSpeakerOwnVoiceStopThreshold 0.35`
    static var defaultThreshold: Float {
        let stored = UserDefaults.standard.double(forKey: "targetSpeakerOwnVoiceStopThreshold")
        return stored > 0 && stored <= 1 ? Float(stored) : TargetSpeakerFilterConfiguration.uncertainSimilarityFloor
    }
}
