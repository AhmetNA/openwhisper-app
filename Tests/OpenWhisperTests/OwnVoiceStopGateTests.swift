import XCTest
@testable import OpenWhisper

final class OwnVoiceStopGateTests: XCTestCase {
    /// Feeds 20 Hz level frames from `from` to `to`, all loud or all quiet.
    private func level(_ gate: inout OwnVoiceStopGate, loud: Bool, from: Double, to: Double) {
        var t = from
        while t <= to + 1e-9 {
            gate.noteLevel(loud: loud, at: t)
            t += 0.05
        }
    }

    /// Scores every 0.5 s starting at `start` while the level stays loud; returns the stop time.
    private func speak(_ gate: inout OwnVoiceStopGate, scores: [Float], start: Double) -> Double? {
        var t = start
        for score in scores {
            level(&gate, loud: true, from: t - 0.5, to: t)
            if gate.record(score: score, at: t) { return t }
            t += 0.5
        }
        return nil
    }

    func testStopsWhenSomeoneElseKeepsTalkingAfterTheUser() {
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 1.5)
        XCTAssertNil(speak(&gate, scores: [0.6, 0.55], start: 1.5))
        // A friend keeps talking: loud, but clearly not the enrolled voice.
        XCTAssertEqual(speak(&gate, scores: [0.1, 0.15, 0.1, 0.12], start: 2.5), 4.0)
    }

    func testSilentWindowsNeverStop() {
        // 27 Sep 00:45:31 — a thinking pause scored 0.14–0.22; the old gate cut the sentence.
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 2)
        XCTAssertNil(speak(&gate, scores: [0.49, 0.43], start: 2))
        var t = 3.0
        for score: Float in [0.138, 0.179, 0.151, 0.142, 0.219, 0.1, 0.1, 0.1] {
            level(&gate, loud: false, from: t - 0.5, to: t)
            XCTAssertFalse(gate.record(score: score, at: t))
            t += 0.5
        }
    }

    func testUsersOwnFluctuatingSpeechNeverStops() {
        // 27 Sep 01:11:49 — 16 s of continuous speech the old 0.40 / 3 s rule cut.
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 1.5)
        let scores: [Float] = [0.544, 0.438, 0.380, 0.444, 0.317, 0.408, 0.400, 0.303, 0.374, 0.494,
                               0.406, 0.313, 0.353, 0.420, 0.404, 0.431, 0.356, 0.333, 0.375, 0.348, 0.350]
        XCTAssertNil(speak(&gate, scores: scores, start: 1.5))
    }

    func testTwoLowScoresInsideRealSpeechDoNotStop() {
        // 27 Sep 01:10:34 — 0.210 and 0.222 back to back while the user was still talking.
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 1.5)
        let scores: [Float] = [0.270, 0.276, 0.511, 0.443, 0.287, 0.298, 0.210, 0.222, 0.359, 0.31, 0.19, 0.18]
        XCTAssertNil(speak(&gate, scores: scores, start: 1.5))
    }

    func testAmbiguousScoresAreTreatedAsTheUser() {
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 1.5)
        XCTAssertNil(speak(&gate, scores: [0.5, 0.1, 0.1, 0.1, 0.35, 0.1, 0.1, 0.1], start: 1.5))
    }

    func testNeverStopsBeforeTheUsersVoiceMatchedOnce() {
        // Low scores on this mic must fall back to Smart Turn, not cut the command.
        var gate = OwnVoiceStopGate()
        level(&gate, loud: true, from: 0, to: 1.5)
        XCTAssertNil(speak(&gate, scores: Array(repeating: 0.15, count: 20), start: 1.5))
    }
}
