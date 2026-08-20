import XCTest
@testable import OpenWhisper

final class AudioSignalProcessorTests: XCTestCase {
    func testQuietSamplesAreBoostedWithoutBeingGated() {
        var samples: [Float] = [0.1, -0.1, 0]

        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        // Asserting the exact product of the gain constant made this a change-detector for
        // tuning rather than a test of behavior. What has to hold is the contract in the name:
        // quiet input is amplified, never gated to silence, sign survives, silence stays silent.
        XCTAssertGreaterThan(samples[0], 0.1)
        XCTAssertLessThan(samples[1], -0.1)
        XCTAssertEqual(samples[0], -samples[1], accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0)
    }

    /// Ties the gain constant to the measurement that set it. Recordings averaging -52 dBFS made
    /// Silero report voiceRuns=0 across 9.65s of real speech, while -47 dBFS transcribed cleanly.
    /// The gain stage must lift the failing level clear of that floor, or the cliff comes back.
    func testVeryQuietSpeechIsLiftedPastTheLevelThatFailedVoiceDetection() {
        let minusFiftyTwoDBFS: Float = 0.00251
        let minusFortySevenDBFS: Float = 0.00447
        var samples: [Float] = [minusFiftyTwoDBFS]

        samples.withUnsafeMutableBufferPointer { buffer in
            AudioSignalProcessor.process(buffer.baseAddress!, count: buffer.count)
        }

        XCTAssertGreaterThan(samples[0], minusFortySevenDBFS)
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
}
