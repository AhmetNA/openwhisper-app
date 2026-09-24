import XCTest
@testable import OpenWhisper

final class VoiceEndpointDetectorTests: XCTestCase {
    private let frame: TimeInterval = 0.05

    private func rms(_ dB: Float) -> Float { pow(10, dB / 20) }

    /// Feeds (dBFS, seconds) runs at 20 Hz; returns the first non-continue decision and its time.
    private func run(
        _ segments: [(dB: Float, seconds: TimeInterval)],
        config: VoiceEndpointDetector.Config = .init(),
        ignoreUntil: TimeInterval? = nil
    ) -> (VoiceEndpointDetector.Decision, TimeInterval)? {
        var detector = VoiceEndpointDetector(startTime: 0, config: config, ignoreUntil: ignoreUntil)
        var t: TimeInterval = 0
        for segment in segments {
            let end = t + segment.seconds
            while t < end - 1e-9 {
                let decision = detector.process(rms: rms(segment.dB), at: t)
                if decision != .continueRecording { return (decision, t) }
                t += frame
            }
        }
        return nil
    }

    func testQuietMicrophoneSpeechIsDetectedAndEndsAfterPause() {
        // This mic's real range: floor around -72, normal speech around -63 dBFS.
        let result = run([(-72, 0.5), (-63, 3), (-72, 3)])
        XCTAssertEqual(result?.0, .stop)
        // Speech ends at 3.5 s; stop ~1 s later, not before.
        XCTAssertEqual(result?.1 ?? 0, 4.5, accuracy: 0.15)
    }

    func testSpeakingImmediatelyAfterTriggerStillEnds() {
        // No quiet lead-in: the floor is first seeded by speech and must settle on the first gap.
        let result = run([(-55, 1), (-75, 0.2), (-55, 2), (-75, 3)])
        XCTAssertEqual(result?.0, .stop)
    }

    func testSilenceOnlyCancelsInsteadOfTranscribing() {
        let result = run([(-72, 10)])
        XCTAssertEqual(result?.0, .cancelNoSpeech)
        XCTAssertEqual(result?.1 ?? 0, 6, accuracy: 0.1)
    }

    func testShortDipsBetweenWordsDoNotEndEarly() {
        var segments: [(dB: Float, seconds: TimeInterval)] = [(-72, 0.5)]
        for _ in 0..<8 { segments += [(-58, 0.6), (-72, 0.8)] }
        segments.append((-72, 3))
        let result = run(segments)
        XCTAssertEqual(result?.0, .stop)
        // Last word ends at 0.5 + 8 * 1.4 - 0.8 = 10.9 s.
        XCTAssertGreaterThan(result?.1 ?? 0, 10.9 + 0.9)
    }

    func testBackgroundNoiseBelowSpeakerDoesNotKeepRecordingOpen() {
        // Room at -70, speaker at -45, then a TV-ish -64 background: well below the midpoint.
        let result = run([(-70, 0.5), (-45, 2), (-64, 4)])
        XCTAssertEqual(result?.0, .stop)
    }

    func testMaxDurationStopsLongDictation() {
        var config = VoiceEndpointDetector.Config()
        config.maxDuration = 5
        let result = run([(-72, 0.5), (-58, 10)], config: config)
        XCTAssertEqual(result?.0, .stopMaxDuration)
    }

    func testLeadingZeroFrameDoesNotBreakEndpointing() {
        let result = run([(-140, 0.05), (-72, 0.5), (-63, 3), (-72, 3)])
        XCTAssertEqual(result?.0, .stop)
    }

    func testLeadingZeroFrameWithSilenceStillCancels() {
        let result = run([(-140, 0.05), (-72, 10)])
        XCTAssertEqual(result?.0, .cancelNoSpeech)
    }

    func testDropoutMidSpeechDoesNotPreventStop() {
        let result = run([(-72, 0.5), (-60, 1.5), (-140, 0.05), (-60, 1.5), (-72, 3)])
        XCTAssertEqual(result?.0, .stop)
    }

    func testOnsetSpikeDoesNotCutQuietSpeechShort() {
        // A -35 clack right at onset, then quiet speech at -63 for 3 s: must not stop mid-speech.
        let result = run([(-72, 0.5), (-35, 0.05), (-63, 3), (-72, 3)])
        XCTAssertEqual(result?.0, .stop)
        XCTAssertGreaterThan(result?.1 ?? 0, 3.55 + 0.9)
    }

    func testMusicTailBeforePauseIsIgnored() {
        // Spotify keeps playing ~0.5 s after the session starts, then the user pauses before
        // speaking. Without the ignore window that tail reads as speech and ends the session.
        let segments: [(dB: Float, seconds: TimeInterval)] = [(-55, 0.1), (-45, 0.5), (-75, 1.5), (-60, 2), (-75, 2)]
        XCTAssertLessThan(run(segments)?.1 ?? 99, 2.2)
        let result = run(segments, ignoreUntil: 0.8)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertGreaterThan(result?.1 ?? 0, 4.1)
    }
}
