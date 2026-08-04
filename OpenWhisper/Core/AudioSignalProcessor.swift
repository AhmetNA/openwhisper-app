import Foundation

/// Small, speech-preserving gain stage used before Whisper receives microphone samples.
/// It intentionally has no noise gate: low-volume speech must not be classified as noise.
enum AudioSignalProcessor {
    /// A modest fixed boost makes distant/quiet speech visible to the model without making
    /// normal speech uncomfortably loud. The soft compressor below handles the extra headroom.
    static let inputGain: Float = 1.65
    static let recoveryGain: Float = 2.35
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
