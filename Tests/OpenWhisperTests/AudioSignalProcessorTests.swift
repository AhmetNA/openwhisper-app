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
}
