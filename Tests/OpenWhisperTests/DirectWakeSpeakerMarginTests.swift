import XCTest
@testable import OpenWhisper

@MainActor
final class DirectWakeSpeakerMarginTests: XCTestCase {
    private func threshold(score: Float, media: Bool) -> Float {
        0.40 - AppState.directWakeSpeakerMargin(score: score, mediaPlaying: media, threshold: 0.40)
    }

    func testWeakWakeKeepsOldThresholds() {
        XCTAssertEqual(threshold(score: 0.33, media: false), 0.40, accuracy: 0.001)
        XCTAssertEqual(threshold(score: 0.39, media: true), 0.38, accuracy: 0.001)
    }

    func testClearWakeAcceptsVoiceFromPointThirty() {
        XCTAssertEqual(threshold(score: 0.40, media: false), 0.30, accuracy: 0.001)
        XCTAssertEqual(threshold(score: 0.57, media: true), 0.30, accuracy: 0.001)
    }

    func testLowerUserThresholdIsNotRaised() {
        let margin = AppState.directWakeSpeakerMargin(score: 0.50, mediaPlaying: true, threshold: 0.25)
        XCTAssertEqual(margin, AppState.mediaWakeSpeakerMargin, accuracy: 0.001)
    }
}
