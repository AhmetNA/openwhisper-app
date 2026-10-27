import XCTest
@testable import OpenWhisper

final class SmartTurnEndpointDetectorTests: XCTestCase {
    func testCertainCompletionScoreUsesShortestDebounce() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.985,
            silenceDuration: 0.99,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.985,
            silenceDuration: 1.0,
            config: config
        ), .stop(probability: 0.985))
    }

    func testVeryHighCompletionScoreUsesShortDebounce() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.95,
            silenceDuration: 1.99,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.95,
            silenceDuration: 2.0,
            config: config
        ), .stop(probability: 0.95))
    }

    func testBorderlineCompletionScoreGetsMoreThinkingTime() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertEqual(
            SmartTurnEndpointDetector.requiredSilence(for: 0.8, config: config),
            2.5
        )
        XCTAssertEqual(
            SmartTurnEndpointDetector.requiredSilence(for: 0.6, config: config),
            3.0
        )
    }

    func testIncompleteTurnUsesLongerSafetyTimeout() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.2,
            silenceDuration: 3.99,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.2,
            silenceDuration: 4.0,
            config: config
        ), .stopAfterIncompleteTimeout)
    }

    func testNoEndpointStopBeforeMinimumListenDuration() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.99,
            silenceDuration: 2.5,
            sessionElapsed: 3.9,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.99,
            silenceDuration: 2.5,
            sessionElapsed: 4.0,
            config: config
        ), .stop(probability: 0.99))
    }

    func testBundledModelLoadsAndReturnsProbability() throws {
        let model = try SmartTurnModel()
        let probability = try model.probability(for: [Float](repeating: 0, count: 16_000))

        XCTAssertTrue(probability.isFinite)
        XCTAssertGreaterThanOrEqual(probability, 0)
        XCTAssertLessThanOrEqual(probability, 1)
    }
}
