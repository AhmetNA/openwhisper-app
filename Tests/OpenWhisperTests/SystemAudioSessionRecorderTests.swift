import XCTest
@testable import OpenWhisper

final class SystemAudioSessionRecorderTests: XCTestCase {
    private let rate = SystemAudioSessionRecorder.sampleRate

    func testPausesNeverSplitTheSessionIntoSeveralClips() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0.25, count: rate * 2))
        recorder.ingest(Array(repeating: 0, count: rate * 5))
        recorder.ingest(Array(repeating: 0.2, count: rate * 2))

        let samples = recorder.finish()
        XCTAssertNotNil(samples)
        // Both sounds are in the one recording, with the 5 s pause shortened to 1 s.
        XCTAssertEqual(samples?.count, rate * 5)
        XCTAssertEqual(samples?.first, 0.25)
        XCTAssertEqual(samples?.last, 0.2)
    }

    func testShortPausesAreKeptWhole() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0.25, count: rate))
        recorder.ingest(Array(repeating: 0, count: rate * 7 / 10))
        recorder.ingest(Array(repeating: 0.25, count: rate))
        XCTAssertEqual(recorder.finish()?.count, rate * 27 / 10)
    }

    func testTrailingSilenceIsShortenedAndSoftSpeechIsKept() {
        let recorder = SystemAudioSessionRecorder()
        // -46 dBFS: below the "heard" threshold but above the pause threshold → kept.
        recorder.ingest(Array(repeating: 0.005, count: rate * 3))
        recorder.ingest(Array(repeating: 0.25, count: rate))
        recorder.ingest(Array(repeating: 0, count: rate * 60))
        XCTAssertEqual(recorder.finish()?.count, rate * 5)
    }

    func testSilentSessionReturnsNothingAndRecorderResets() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0, count: rate * 10))
        recorder.ingest(Array(repeating: 0.3, count: rate / 10))
        XCTAssertNil(recorder.finish())

        recorder.ingest(Array(repeating: 0.3, count: rate))
        XCTAssertEqual(recorder.finish()?.count, rate)
        XCTAssertNil(recorder.finish())
    }
}
