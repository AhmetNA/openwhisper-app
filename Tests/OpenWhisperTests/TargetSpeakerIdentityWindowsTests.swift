import XCTest
@testable import OpenWhisper

final class TargetSpeakerIdentityWindowsTests: XCTestCase {
    private func frames(_ groups: [(Int, [Int])]) -> [TargetSpeakerActivityFrame] {
        var result: [TargetSpeakerActivityFrame] = []
        for (count, slots) in groups {
            for _ in 0..<count {
                let index = result.count
                result.append(TargetSpeakerActivityFrame(frameIndex: index,
                    startTime: Double(index) * 0.08, endTime: Double(index + 1) * 0.08,
                    probabilities: [], activeSpeakerSlots: slots))
            }
        }
        return result
    }

    func testPoolsFragmentedSoloSpeechWithoutSilence() {
        let input = frames([(14, [0]), (4, []), (12, [0])]) // 1.12 + 0.96 s
        let windows = TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 38_400)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].ranges, [0..<17_920, 23_040..<29_120])
        XCTAssertEqual(windows[0].ranges.reduce(0) { $0 + $1.count }, 24_000)
    }

    func testNeverPoolsDifferentSpeakers() {
        let input = frames([(14, [0]), (12, [1])])
        XCTAssertTrue(TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 33_280).isEmpty)
    }

    func testOverlapDoesNotContributeIdentityEvidence() {
        let input = frames([(10, [0]), (20, [0, 1]), (8, [0])])
        XCTAssertTrue(TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 48_640).isEmpty)
    }

    func testShortSpeechStillNeedsMinimumEvidence() {
        let input = frames([(17, [0])]) // 1.36 seconds cannot be padded/repeated
        XCTAssertTrue(TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 21_760).isEmpty)
    }

    func testLongRunKeepsEstablishedOverlappingWindows() {
        let input = frames([(30, [0]), (5, []), (5, [0])])
        let windows = TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 51_200)
        XCTAssertEqual(windows.map(\.ranges), [[0..<24_000], [12_000..<36_000]])
    }

    func testClipsLastFrameToActualAudioLength() {
        let input = frames([(19, [0])])
        XCTAssertTrue(TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 23_999).isEmpty)
        XCTAssertEqual(TargetSpeakerIdentityWindows.make(frames: input, audioSampleCount: 24_000).first?.ranges, [0..<24_000])
    }
}
