import XCTest
@testable import OpenWhisper

final class RecordingStatsTests: XCTestCase {
    private func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    func testSpeechTimePartsAndPause() {
        var accumulator = RecordingStatsAccumulator()
        let quiet: Float = 0.0005 // ~-70 dBFS
        // Fed in odd-sized pieces, like real segments.
        let audio = noise(1, amplitude: quiet) + tone(2, amplitude: 0.1) + noise(1, amplitude: quiet)
            + tone(1, amplitude: 0.1) + noise(0.5, amplitude: quiet)
        var start = 0
        while start < audio.count {
            let end = min(start + 7_777, audio.count)
            accumulator.add(audio[start..<end])
            start = end
        }
        let stats = accumulator.finish(transcript: "merhaba Jarvis şarkıyı aç lütfen", whisperSegments: 2)

        XCTAssertEqual(stats.totalSeconds, 5.5, accuracy: 0.01)
        XCTAssertEqual(stats.speechSeconds, 3, accuracy: 0.1)
        XCTAssertEqual(stats.speechParts, 2)
        XCTAssertEqual(stats.longestPauseSeconds, 1, accuracy: 0.1)
        XCTAssertEqual(stats.peakDBFS, -20, accuracy: 0.5)
        XCTAssertEqual(stats.speechLevelDBFS ?? 0, -23, accuracy: 1)
        XCTAssertEqual(stats.wordCount, 5)
        XCTAssertEqual(stats.wordsPerMinute ?? 0, 100, accuracy: 5)
        XCTAssertEqual(stats.clippedPercent, 0)
    }

    func testSilenceHasNoSpeech() {
        var accumulator = RecordingStatsAccumulator()
        accumulator.add(Array(repeating: Float(0), count: 32_000))
        let stats = accumulator.finish(transcript: "[BLANK_AUDIO]")
        XCTAssertEqual(stats.speechSeconds, 0)
        XCTAssertEqual(stats.speechParts, 0)
        XCTAssertNil(stats.speechLevelDBFS)
        XCTAssertEqual(stats.wordCount, 0)
    }

    func testOldIndexEntriesDecodeWithoutStats() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","createdAt":0,"sampleCount":16000,"previewText":"a"}]"#
        let decoded = try JSONDecoder().decode([SavedRecording].self, from: Data(json.utf8))
        XCTAssertNil(decoded.first?.stats)
    }
}
