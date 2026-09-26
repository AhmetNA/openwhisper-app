import XCTest
@testable import OpenWhisper

final class OwnVoiceStopGateTests: XCTestCase {
    func testStopsWhenUserStopsWhileSomeoneElseKeepsTalking() {
        var gate = OwnVoiceStopGate(threshold: 0.4)
        XCTAssertFalse(gate.record(score: 0.6, at: 1.0))
        XCTAssertFalse(gate.record(score: 0.55, at: 1.5))
        // A friend keeps talking: loud, but not the enrolled voice.
        XCTAssertFalse(gate.record(score: 0.1, at: 2.0))
        XCTAssertFalse(gate.record(score: 0.15, at: 2.5))
        XCTAssertTrue(gate.record(score: 0.1, at: 3.0))
    }

    func testUserSpeakingAgainResetsThePause() {
        var gate = OwnVoiceStopGate(threshold: 0.4)
        XCTAssertFalse(gate.record(score: 0.6, at: 1.0))
        XCTAssertFalse(gate.record(score: 0.1, at: 2.0))
        XCTAssertFalse(gate.record(score: 0.5, at: 2.4))
        XCTAssertFalse(gate.record(score: 0.1, at: 3.5))
        XCTAssertTrue(gate.record(score: 0.1, at: 3.9))
    }

    func testNeverStopsBeforeTheUsersVoiceMatchedOnce() {
        // Low scores on this mic must fall back to the level-only detector, not cut the command.
        var gate = OwnVoiceStopGate(threshold: 0.4)
        for i in 0..<20 {
            XCTAssertFalse(gate.record(score: 0.2, at: Double(i) * 0.5))
        }
    }
}
