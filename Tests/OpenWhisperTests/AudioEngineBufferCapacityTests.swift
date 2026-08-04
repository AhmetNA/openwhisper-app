import AVFoundation
import XCTest
@testable import OpenWhisper

final class AudioEngineBufferCapacityTests: XCTestCase {
    private let targetSampleRate: Double = 16_000
    private let df3SampleRate: Double = 48_000

    private func assertOutputCapacityCoversWorstCase(
        nativeSampleRate: Double,
        deepFilterActive: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capacities = AudioEngine.bufferCapacities(
            nativeSampleRate: nativeSampleRate,
            deepFilterActive: deepFilterActive
        )

        // The real maximum number of 16kHz output frames a single callback could ever produce,
        // computed independently of the production formula so this test can't just echo it back.
        let maxSourceFrames: Double
        let sourceRate: Double
        if deepFilterActive {
            let df3InputAt48k = Double(capacities.df3Resampled ?? capacities.monoInput)
            maxSourceFrames = df3InputAt48k + 512
            sourceRate = df3SampleRate
            XCTAssertEqual(capacities.df3Output, AVAudioFrameCount(maxSourceFrames), file: file, line: line)
        } else {
            maxSourceFrames = Double(capacities.monoInput)
            sourceRate = nativeSampleRate
            XCTAssertNil(capacities.df3Output, file: file, line: line)
            XCTAssertNil(capacities.df3Resampled, file: file, line: line)
        }

        let worstCaseOutputFrames = maxSourceFrames * targetSampleRate / sourceRate
        XCTAssertGreaterThan(
            Double(capacities.converted),
            worstCaseOutputFrames,
            "converted buffer capacity must exceed the real maximum output frame count",
            file: file,
            line: line
        )
    }

    func testDeepFilterOnAt44100() {
        assertOutputCapacityCoversWorstCase(nativeSampleRate: 44_100, deepFilterActive: true)
    }

    func testDeepFilterOnAt48000() {
        assertOutputCapacityCoversWorstCase(nativeSampleRate: 48_000, deepFilterActive: true)
    }

    func testDeepFilterOffAt44100() {
        assertOutputCapacityCoversWorstCase(nativeSampleRate: 44_100, deepFilterActive: false)
    }

    func testDeepFilterOnAt16000() {
        assertOutputCapacityCoversWorstCase(nativeSampleRate: 16_000, deepFilterActive: true)
    }

    func testDeepFilterOnAt96000() {
        assertOutputCapacityCoversWorstCase(nativeSampleRate: 96_000, deepFilterActive: true)
    }

    func testDf3ResamplerSkippedWhenNativeRateMatchesDf3Rate() {
        let capacities = AudioEngine.bufferCapacities(nativeSampleRate: 48_000, deepFilterActive: true)
        XCTAssertNil(capacities.df3Resampled)
        XCTAssertEqual(capacities.df3Output, capacities.monoInput + 512)
    }

    func testDf3ResamplerPresentWhenNativeRateDiffersFromDf3Rate() {
        let capacities = AudioEngine.bufferCapacities(nativeSampleRate: 44_100, deepFilterActive: true)
        XCTAssertNotNil(capacities.df3Resampled)
        XCTAssertEqual(capacities.df3Output, (capacities.df3Resampled ?? 0) + 512)
    }
}
