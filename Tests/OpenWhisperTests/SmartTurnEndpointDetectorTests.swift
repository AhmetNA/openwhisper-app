import XCTest
@testable import OpenWhisper

final class SmartTurnEndpointDetectorTests: XCTestCase {
    func testVeryHighCompletionScoreUsesShortDebounce() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.985,
            silenceDuration: 1.19,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.985,
            silenceDuration: 1.2,
            config: config
        ), .stop(probability: 0.985))
    }

    func testBorderlineCompletionScoreGetsMoreThinkingTime() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertEqual(
            SmartTurnEndpointDetector.requiredSilence(for: 0.8, config: config),
            1.6
        )
        XCTAssertEqual(
            SmartTurnEndpointDetector.requiredSilence(for: 0.6, config: config),
            2.0
        )
    }

    func testIncompleteTurnUsesLongerSafetyTimeout() {
        let config = SmartTurnEndpointDetector.Config()

        XCTAssertNil(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.2,
            silenceDuration: 2.99,
            config: config
        ))
        XCTAssertEqual(SmartTurnEndpointDetector.endpointDecision(
            probability: 0.2,
            silenceDuration: 3.0,
            config: config
        ), .stopAfterIncompleteTimeout)
    }

    func testBundledModelLoadsAndReturnsProbability() throws {
        let model = try SmartTurnModel()
        let probability = try model.probability(for: [Float](repeating: 0, count: 16_000))

        XCTAssertTrue(probability.isFinite)
        XCTAssertGreaterThanOrEqual(probability, 0)
        XCTAssertLessThanOrEqual(probability, 1)
    }
}
