import Foundation

/// Small, speech-preserving gain stage used before Whisper receives microphone samples.
/// It intentionally has no noise gate: low-volume speech must not be classified as noise.
enum AudioSignalProcessor {
    /// A modest fixed boost makes distant/quiet speech visible to the model without making
    /// normal speech uncomfortably loud. The soft compressor below handles the extra headroom.
    /// This value is the correct default only when Apple voice processing (VPIO) is NOT active
    /// on the capture path -- see `voiceProcessingInputGain` for the VPIO case.
    static let inputGain: Float = 1.65
    /// Gain used while Apple voice processing (VPIO) is active on the capture path. VPIO runs its
    /// own AGC that already normalizes the incoming signal toward full scale before it reaches
    /// this stage, so stacking the full 1.65x on top pushes the compressor into constant
    /// gain-reduction ("pumping") and audibly distorts speech, eating the accuracy benefit the
    /// noise suppression was added for. ~1.2x keeps a little headroom recovery for quiet speech
    /// without re-doing work the AGC already did. Chosen empirically in the 1.15-1.25 range asked
    /// for by the task; 1.2 sits in the middle so a slightly-under or slightly-over AGC still
    /// leaves margin before the compressor knee at 0.42.
    static let voiceProcessingInputGain: Float = 1.2
    static let recoveryGain: Float = 2.35
    /// Recovery-pass gain used when the live capture used voice processing. Scaled by the same
    /// ratio as inputGain -> voiceProcessingInputGain (about 0.727x) so the second decode still
    /// gets a proportionally bigger boost than the live pass, without re-stacking the full,
    /// un-scaled recovery gain on top of VPIO's AGC the way the live-path bug did before this fix.
    static let voiceProcessingRecoveryGain: Float = recoveryGain * (voiceProcessingInputGain / inputGain)
    private static let compressionThreshold: Float = 0.42
    private static let compressionRatio: Float = 3.0
    private static let limiterCeiling: Float = 0.98

    /// Whether the in-progress (or most recently started) recording's capture path has Apple
    /// voice processing (VPIO) active. `AudioEngine.startRecording` is the sole writer, and it
    /// writes this once, synchronously, before installing the audio tap that calls `process`.
    /// `recoverySamples` is the only reader outside of `process`'s own default-argument
    /// evaluation; it runs from `WhisperTranscriber` strictly after that same recording's audio
    /// has been captured (never concurrently with a *different* recording's write), so this needs
    /// no lock -- there is exactly one writer per recording and all reads happen inside that
    /// recording's lifetime.
    static var captureUsedVoiceProcessing: Bool = false

    /// The gain `process` falls back to when the caller does not specify one explicitly. Mirrors
    /// whichever capture mode `AudioEngine` last recorded in `captureUsedVoiceProcessing`.
    static var defaultGain: Float {
        captureUsedVoiceProcessing ? voiceProcessingInputGain : inputGain
    }

    /// Applies a fixed gain followed by a gentle soft-knee-like compressor in place. This is
    /// allocation-free because it runs on the audio callback path.
    static func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gain: Float = defaultGain) {
        guard count > 0 else { return }

        for index in 0..<count {
            let boosted = samples[index] * gain
            let magnitude = abs(boosted)
            let compressedMagnitude: Float
            if magnitude > compressionThreshold {
                compressedMagnitude = compressionThreshold
                    + (magnitude - compressionThreshold) / compressionRatio
            } else {
                compressedMagnitude = magnitude
            }

            let limited = min(compressedMagnitude, limiterCeiling)
            samples[index] = boosted >= 0 ? limited : -limited
        }
    }

    /// Produces the alternate pass used only when the first Whisper decode is weak. It is
    /// intentionally stronger than the live path, so a second decode can recover quiet words
    /// without permanently making every recording louder. Mode-aware via
    /// `captureUsedVoiceProcessing` so a VPIO recording does not get the full, un-scaled
    /// recovery gain stacked on top of VPIO's own AGC.
    static func recoverySamples(from source: [Float]) -> [Float] {
        guard !source.isEmpty else { return [] }
        let gain = captureUsedVoiceProcessing ? voiceProcessingRecoveryGain : recoveryGain
        var samples = source
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count, gain: gain)
        }
        return samples
    }
}
