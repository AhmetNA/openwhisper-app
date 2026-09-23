import XCTest
@testable import OpenWhisper

final class SystemAudioActivityDetectorTests: XCTestCase {
    func testAudibleClipFinishesAfterQuietTailAndRearms() {
        let detector = SystemAudioActivityDetector()
        var clips: [[Float]] = []
        detector.onClip = { clips.append($0) }

        detector.ingest(Array(repeating: 0.25, count: 16_000))
        XCTAssertTrue(detector.isRecording)
        detector.ingest(Array(repeating: 0, count: 32_000))
        XCTAssertFalse(detector.isRecording)
        XCTAssertEqual(clips.count, 1)
        XCTAssertGreaterThan(clips[0].count, 16_000)

        detector.ingest(Array(repeating: 0.2, count: 16_000))
        detector.finish()
        XCTAssertEqual(clips.count, 2)
    }

    func testBriefSoundIsNotSavedAndNoBufferEndCanBeDetected() {
        let detector = SystemAudioActivityDetector()
        var clips: [[Float]] = []
        detector.onClip = { clips.append($0) }

        detector.ingest(Array(repeating: 0.3, count: 1_600))
        detector.checkForSilence(now: ProcessInfo.processInfo.systemUptime + 3)
        XCTAssertTrue(clips.isEmpty)

        detector.ingest(Array(repeating: 0.3, count: 16_000))
        detector.checkForSilence(now: ProcessInfo.processInfo.systemUptime + 3)
        XCTAssertEqual(clips.count, 1)
        XCTAssertFalse(detector.isRecording)
    }
}
