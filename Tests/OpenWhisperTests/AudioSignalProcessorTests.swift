import XCTest
@testable import OpenWhisper

final class AudioSignalProcessorTests: XCTestCase {
    func testQuietSamplesAreBoostedWithoutBeingGated() {
        var samples: [Float] = [0.1, -0.1, 0]

        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertEqual(samples[0], 0.165, accuracy: 0.001)
        XCTAssertEqual(samples[1], -0.165, accuracy: 0.001)
        XCTAssertEqual(samples[2], 0)
    }

    func testCompressorKeepsBoostedPeakBelowLimiterCeiling() {
        var samples: [Float] = [0.8, -0.8]

        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertLessThanOrEqual(abs(samples[0]), 0.98)
        XCTAssertLessThanOrEqual(abs(samples[1]), 0.98)
        XCTAssertGreaterThan(abs(samples[0]), 0.42)
    }

    func testRecoveryPassIsStrongerButPreservesLength() {
        let source: [Float] = [0.05, -0.05, 0.1]
        let recovered = AudioSignalProcessor.recoverySamples(from: source)

        XCTAssertEqual(recovered.count, source.count)
        XCTAssertGreaterThan(abs(recovered[0]), abs(source[0]))
        XCTAssertGreaterThan(abs(recovered[2]), abs(source[2]))
    }

    /// `captureUsedVoiceProcessing` defaults to false; verify that starting point explicitly so a
    /// leftover `true` from another test (or test ordering) can't silently change this test's
    /// expectations.
    func testDefaultGainMatchesNonVoiceProcessingModeWhenFlagIsFalse() {
        AudioSignalProcessor.captureUsedVoiceProcessing = false
        defer { AudioSignalProcessor.captureUsedVoiceProcessing = false }

        var samples: [Float] = [0.1]
        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertEqual(samples[0], 0.1 * AudioSignalProcessor.inputGain, accuracy: 0.0005)
    }

    /// VPIO's own AGC already normalizes the signal, so stacking the full 1.65x live gain on top
    /// of it causes pumping/distortion (see the comment on `voiceProcessingInputGain`). When
    /// AudioEngine records that voice processing was actually active, `process` must fall back to
    /// the reduced VPIO gain instead of the default -- without the caller having to pass `gain:`
    /// explicitly, since AudioEngine's real tap call also omits it and relies on the default.
    func testProcessUsesReducedGainWhenCaptureUsedVoiceProcessing() {
        AudioSignalProcessor.captureUsedVoiceProcessing = true
        defer { AudioSignalProcessor.captureUsedVoiceProcessing = false }

        var samples: [Float] = [0.1]
        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertEqual(samples[0], 0.1 * AudioSignalProcessor.voiceProcessingInputGain, accuracy: 0.0005)
        XCTAssertLessThan(AudioSignalProcessor.voiceProcessingInputGain, AudioSignalProcessor.inputGain)
        // Task asked for a value in the 1.15-1.25 range.
        XCTAssertGreaterThanOrEqual(AudioSignalProcessor.voiceProcessingInputGain, 1.15)
        XCTAssertLessThanOrEqual(AudioSignalProcessor.voiceProcessingInputGain, 1.25)
    }

    /// The recovery pass (called separately by WhisperTranscriber, which this test does not
    /// touch) must also be mode-aware, otherwise a VPIO recording would get the full, un-scaled
    /// 2.35x recovery gain stacked on top of VPIO's AGC -- worse than the live-path bug this
    /// change fixes.
    func testRecoverySamplesUseReducedGainWhenCaptureUsedVoiceProcessing() {
        AudioSignalProcessor.captureUsedVoiceProcessing = true
        defer { AudioSignalProcessor.captureUsedVoiceProcessing = false }

        let source: [Float] = [0.1]
        let recovered = AudioSignalProcessor.recoverySamples(from: source)

        XCTAssertEqual(recovered[0], 0.1 * AudioSignalProcessor.voiceProcessingRecoveryGain, accuracy: 0.0005)
        XCTAssertLessThan(AudioSignalProcessor.voiceProcessingRecoveryGain, AudioSignalProcessor.recoveryGain)
    }
}
