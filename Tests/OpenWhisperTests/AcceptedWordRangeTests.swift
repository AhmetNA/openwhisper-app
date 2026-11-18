import XCTest
@testable import OpenWhisper

final class AcceptedWordRangeTests: XCTestCase {
    private func word(_ text: String, _ start: Float, _ end: Float) -> WhisperTimedWord {
        WhisperTimedWord(word: text, start: start, end: end, probability: 0.9)
    }

    // 1.02–3.84 s accepted; a 0.26 s noise run at 4.10 s dropped (log, 18 Nov 2026 01:00:41).
    private let accepted = [TargetSpeakerAcceptedRange(start: 16_320, end: 61_440)]

    func testAllWordsInsideAcceptedAudio() {
        let words = [word(" Döner", 1.1, 1.5), word(" sermayeli", 1.5, 2.2), word(" nedir?", 3.2, 3.8)]
        XCTAssertTrue(TargetSpeakerDiarizationResult.allWordsInAcceptedRanges(words, ranges: accepted))
    }

    func testWordInDroppedAudioBlocksReuse() {
        let words = [word(" Döner", 1.1, 1.5), word(" evet", 4.1, 4.35)]
        XCTAssertFalse(TargetSpeakerDiarizationResult.allWordsInAcceptedRanges(words, ranges: accepted))
    }

    func testNoWordsBlocksReuse() {
        XCTAssertFalse(TargetSpeakerDiarizationResult.allWordsInAcceptedRanges([], ranges: accepted))
        XCTAssertFalse(TargetSpeakerDiarizationResult.allWordsInAcceptedRanges([word(" a", 1.2, 1.4)], ranges: []))
    }
}
