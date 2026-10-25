import XCTest
@testable import OpenWhisper

final class ListeningModeTests: XCTestCase {
    func testShortModePreservesSpecialFollowUpTiming() {
        var level = VoiceEndpointDetector.Config().afterUnreadRecap
        var smart = SmartTurnEndpointDetector.Config()
        ListeningMode.short.apply(to: &level)
        ListeningMode.short.apply(to: &smart)
        XCTAssertEqual(level.noSpeechTimeout, 2)
        XCTAssertEqual(level.silenceToStop, 1.5)
        XCTAssertEqual(SmartTurnEndpointDetector.requiredSilence(for: 0.99, config: smart), 1.5)
    }

    func testRelaxedModeDoesNotEndDuringThinkingPause() {
        var smart = SmartTurnEndpointDetector.Config()
        ListeningMode.relaxed.apply(to: &smart)
        for probability: Float in [0.99, 0.95, 0.8, 0.6, 0.4] {
            XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
                probability: probability, silenceDuration: 4.9, config: smart))
        }
        XCTAssertEqual(SmartTurnEndpointDetector.requiredSilence(for: 0.99, config: smart), 5)
        XCTAssertEqual(SmartTurnEndpointDetector.requiredSilence(for: 0.4, config: smart), 10)
    }

    func testRelaxedFollowUpOutlivesItsStartWindow() {
        var level = VoiceEndpointDetector.Config().afterUnreadRecap
        level.maxDuration = 6
        ListeningMode.relaxed.apply(to: &level)
        XCTAssertEqual(level.noSpeechTimeout, 10)
        XCTAssertEqual(level.silenceToStop, 10)
        XCTAssertGreaterThan(level.maxDuration, level.noSpeechTimeout + level.silenceToStop)
        XCTAssertTrue(level.allowsOnsetAtDeadline)
    }
}
