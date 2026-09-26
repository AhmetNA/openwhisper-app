import XCTest
@testable import OpenWhisper

final class SpeakerBreakdownTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.0001, count: Int(seconds * 16_000))
    }

    func testSplitsOwnAndOtherVoicesByAcceptedRanges() {
        // 1 s quiet, 2 s loud (own), 1 s quiet, 1 s softer (someone else).
        let audio = quiet(1) + tone(2, amplitude: 0.1) + quiet(1) + tone(1, amplitude: 0.01)
        let levels = SpeakerSplitLevels.measure(
            samples: audio,
            overlapSampleCount: 0,
            ownRanges: [TargetSpeakerAcceptedRange(start: 16_000, end: 48_000)]
        )
        XCTAssertEqual(levels.own.seconds, 2, accuracy: 0.05)
        XCTAssertEqual(levels.others.seconds, 1, accuracy: 0.05)
        XCTAssertEqual(levels.own.dbfs ?? 0, -23, accuracy: 1)
        XCTAssertEqual(levels.others.dbfs ?? 0, -43, accuracy: 1)
        XCTAssertEqual(levels.gapDB ?? 0, 20, accuracy: 1)
        XCTAssertEqual(levels.undecided.frames, 0)
    }

    func testNoSplitPutsVoiceInUndecided() {
        let levels = SpeakerSplitLevels.measure(samples: quiet(1) + tone(1, amplitude: 0.1), overlapSampleCount: 0, ownRanges: nil)
        XCTAssertEqual(levels.undecided.seconds, 1, accuracy: 0.05)
        XCTAssertEqual(levels.own.frames + levels.others.frames, 0)
        XCTAssertNil(levels.gapDB)
    }

    func testOverlapIsSkipped() {
        // The first second repeats the previous batch and must not be counted again.
        let audio = tone(1, amplitude: 0.1) + quiet(2)
        let levels = SpeakerSplitLevels.measure(samples: audio, overlapSampleCount: 16_000, ownRanges: [])
        XCTAssertEqual(levels.own.frames + levels.others.frames, 0)
    }

    func testHeaderListsWordsHeardPerVoice() {
        let own = SpeakerSplitLevels.measure(samples: quiet(1) + tone(1, amplitude: 0.1), overlapSampleCount: 0,
                                             ownRanges: [TargetSpeakerAcceptedRange(start: 0, end: 32_000)])
        let others = SpeakerSplitLevels.measure(samples: quiet(1) + tone(1, amplitude: 0.01), overlapSampleCount: 0, ownRanges: [])
        let batches = [
            SpeakerBatchLog(batch: 1, decision: "partial", levels: own, ownText: "Jarvis şarkıyı aç", othersText: "yemek hazır"),
            SpeakerBatchLog(batch: 2, decision: "rejected", levels: others, othersText: "gel buraya"),
        ]
        let lines = SpeakerBatchLog.headerLines(targetSpeakerEnabled: true, batches: batches)
        XCTAssertTrue(lines[0].hasPrefix("Speakers: own 3 words, 1.0 s @ -23"), lines[0])
        XCTAssertTrue(lines[0].contains("others 4 words, 1.0 s @ -43"), lines[0])
        XCTAssertTrue(lines[0].contains("gap 20."), lines[0])
        XCTAssertEqual(lines[1], "Own voice heard: \"Jarvis şarkıyı aç\"")
        XCTAssertEqual(lines[2], "Other voices heard: \"yemek hazır gel buraya\"")
        XCTAssertTrue(lines.contains("  other voices: \"gel buraya\""))

        XCTAssertEqual(SpeakerBatchLog.headerLines(targetSpeakerEnabled: false, batches: batches).count, 1)
    }

    func testRenderKeepsPunctuationAttached() {
        let words = ["Merhaba", ",", "nasılsın", "?"].enumerated().map {
            WhisperTimedWord(word: $0.element, start: Float($0.offset), end: Float($0.offset) + 0.5, probability: 1)
        }
        XCTAssertEqual(TargetSpeakerDiarizationResult.render(words: words), "Merhaba, nasılsın?")
    }
}
