import XCTest
@testable import OpenWhisper

final class WakeProbationTests: XCTestCase {
    private let profile = try! TargetSpeakerProfile(
        modelIdentifier: "test", embeddings: [Array(repeating: 0.1, count: TargetSpeakerProfile.expectedEmbeddingDimension)])

    func testExpiresWithoutTheUsersVoice() {
        var probation = WakeProbation(startTime: 10, profile: profile)
        XCTAssertFalse(probation.record(score: 0.31, threshold: 0.4))
        XCTAssertFalse(probation.expired(at: 14.9))
        XCTAssertTrue(probation.expired(at: 15))
    }

    func testAWindowAtTheThresholdConfirmsOnce() {
        var probation = WakeProbation(startTime: 0, profile: profile)
        XCTAssertTrue(probation.record(score: 0.4, threshold: 0.4))
        XCTAssertFalse(probation.record(score: 0.6, threshold: 0.4))
        XCTAssertFalse(probation.expired(at: 5))
    }

    func testWakeMatchConfirms() {
        var probation = WakeProbation(startTime: 0, profile: profile)
        probation.confirm()
        XCTAssertFalse(probation.expired(at: 5))
    }
}
