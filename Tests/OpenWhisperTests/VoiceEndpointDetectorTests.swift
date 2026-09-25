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

    func testSteadyOutsideNoiseAboveOldThresholdStillEnds() {
        // Earbuds in, the Mac mic hears the street: room seeded at -70, speaker -40, then a
        // -52 background that sat above the old -58 end threshold forever.
        let result = run([(-70, 0.3), (-40, 2), (-52, 8)])
        XCTAssertEqual(result?.0, .stop)
        XCTAssertLessThan(result?.1 ?? 99, 2.3 + 3)
    }

    func testFluctuatingOutsideNoiseStillEnds() {
        var segments: [(dB: Float, seconds: TimeInterval)] = [(-70, 0.3), (-40, 2)]
        for _ in 0..<40 { segments += [(-50, 0.1), (-57, 0.1)] }
        let result = run(segments)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertLessThan(result?.1 ?? 99, 2.3 + 3.5)
    }

    func testSpeechOverOutsideNoiseDoesNotEndEarly() {
        // Talking over a -52 background with short word gaps: must stay open until speech ends.
        var segments: [(dB: Float, seconds: TimeInterval)] = [(-70, 0.3)]
        for _ in 0..<10 { segments += [(-40, 0.5), (-52, 0.3)] }
        segments.append((-52, 6))
        let result = run(segments)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertGreaterThan(result?.1 ?? 0, 0.3 + 10 * 0.8 - 0.3 + 0.9)
    }

    func testCloseTalkEndsSoonerOverLoudRoom() {
        // Headset mic: voice -25, room -50. A -35 background right after the voice (60% of the
        // way up) is "not the speaker" for close talk: stop one pause after the voice ends.
        let segments: [(dB: Float, seconds: TimeInterval)] = [(-50, 0.3), (-25, 2), (-35, 1.4), (-50, 4)]
        let closeTalk = run(segments, config: .closeTalk)?.1 ?? 99
        XCTAssertEqual(closeTalk, 3.3, accuracy: 0.2)
        XCTAssertGreaterThanOrEqual(run(segments)?.1 ?? 0, closeTalk)
    }

    func testCloseTalkKeepsWordGapsOpen() {
        var segments: [(dB: Float, seconds: TimeInterval)] = [(-50, 0.3)]
        for _ in 0..<6 { segments += [(-25, 0.5), (-45, 0.4)] }
        segments.append((-50, 3))
        let result = run(segments, config: .closeTalk)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertGreaterThan(result?.1 ?? 0, 0.3 + 6 * 0.9 - 0.4 + 0.9)
    }

    func testHeadsetDigitalSilenceEndsRecording() {
        // Buds gate their mic to exact zeros between words; after speech that is a pause.
        let result = run([(-140, 0.8), (-22, 1.5), (-140, 5)], config: .closeTalk)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertEqual(result?.1 ?? 99, 2.3 + 1.0, accuracy: 0.15)
    }

    func testHeadsetNoiseBlipBeforeSpeechDoesNotEndEarly() {
        // Call-mode start-up zeros, a -60 blip, a long pause, then the command.
        let result = run([(-140, 0.8), (-60, 0.3), (-140, 1.5), (-22, 1.5), (-140, 5)], config: .closeTalk)
        XCTAssertEqual(result?.0, .stop)
        XCTAssertGreaterThan(result?.1 ?? 0, 4.1 + 0.9)
    }
}
