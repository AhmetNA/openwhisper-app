import Foundation

/// Small, speech-preserving gain stage used before Whisper receives microphone samples.
/// It intentionally has no noise gate: low-volume speech must not be classified as noise.
enum AudioSignalProcessor {
    /// Sized from measured recordings, not guessed. Across nine dictations the raw microphone
    /// level ran -63.0 to -43.0 dBFS mean with peaks never above -22.4 dBFS, and the outcome
    /// split cleanly: every recording at -47.3 dBFS or louder transcribed correctly, while
    /// -52.0 dBFS produced voiceRuns=0 (Silero found no speech at all in 9.65s) and -52.3 dBFS
    /// produced a silence hallucination. The old 1.65 (+4.3 dB) left that cliff intact.
    ///
    /// 8.0 is +18 dB, which moves a -52 dBFS recording to about -34 dBFS — well clear of the
    /// -47 dBFS floor where everything worked — while putting the loudest observed peak near
    /// -4.4 dBFS, so the compressor below finally does the job its comment describes instead of
    /// sitting inert. Typical peaks land around -12 dBFS, under the 0.42 threshold, untouched.
    static let inputGain: Float = 8.0
    /// Applied on top of `inputGain`, not instead of it: the recovery pass re-processes samples
    /// that already carry the input gain, so the effective factor is the product. It was 2.35
    /// against a 1.65 base (3.88x total); keeping 2.35 against 8.0 would mean 18.8x and drive
    /// every recovery decode into the limiter. 1.5 keeps recovery a real +3.5 dB push over the
    /// normal pass without crushing it.
    static let recoveryGain: Float = 1.5
    private static let compressionThreshold: Float = 0.42
    private static let compressionRatio: Float = 3.0
    private static let limiterCeiling: Float = 0.98

    /// Applies a fixed gain followed by a gentle soft-knee-like compressor in place. This is
    /// allocation-free because it runs on the audio callback path.
    static func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gain: Float = inputGain) {
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
    /// without permanently making every recording louder.
    static func recoverySamples(from source: [Float]) -> [Float] {
        guard !source.isEmpty else { return [] }
        var samples = source
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            process(baseAddress, count: buffer.count, gain: recoveryGain)
        }
        return samples
    }
}
