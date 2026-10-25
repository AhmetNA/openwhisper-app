import XCTest
@testable import OpenWhisper

final class WhisperLanguageRecoveryTests: XCTestCase {
    private func pass(_ text: String, foreign: Bool = false, weak: Bool = false,
                      confidence: Float = -0.2, words: [WhisperTimedWord] = []) -> WhisperTranscriber.DecodePass {
        .init(text: text, words: words, averageLogprob: confidence, needsRecovery: weak, isForeign: foreign)
    }

    func testForeignResultRetriesAudioInTurkishAndKeepsRecoveredTimings() async throws {
        let audio: [Float] = [0.01, -0.02, 0.03]
        let words = [WhisperTimedWord(word: "Merhaba", start: 0.1, end: 0.5, probability: 0.9)]
        var calls = 0
        let result = try await WhisperTranscriber.decodeWithRecovery(audioData: audio, language: "") { samples, language, recovery in
            calls += 1
            if calls == 1 {
                XCTAssertEqual(samples, audio)
                XCTAssertEqual(language, "")
                XCTAssertFalse(recovery)
                return self.pass("Bonjour tout le monde", foreign: true, confidence: -0.1)
            }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(language, "tr")
            XCTAssertTrue(recovery)
            XCTAssertEqual(samples.count, audio.count)
            XCTAssertNotEqual(samples, audio)
            // A valid recovery wins even when the foreign result was more confident.
            return self.pass("Merhaba", confidence: -0.8, words: words)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "Merhaba")
        XCTAssertEqual(result.words, words)
    }

    func testValidTurkishEnglishAndMixedResultsDoNotRetry() async throws {
        for text in ["Yeni sohbet aç", "Open a new chat", "Claude Code'da PR aç"] {
            var calls = 0
            let result = try await WhisperTranscriber.decodeWithRecovery(audioData: [0.01], language: "tr") { _, _, _ in
                calls += 1
                return self.pass(text)
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result.text, text)
        }
    }

    func testSecondForeignResultFailsAfterOneRetry() async {
        var calls = 0
        do {
            _ = try await WhisperTranscriber.decodeWithRecovery(audioData: [0.01], language: "tr") { _, _, _ in
                calls += 1
                return self.pass("Das ist eine fremde Sprache", foreign: true)
            }
            XCTFail("Foreign text must not reach delivery")
        } catch TranscriberError.unsupportedTranscriptLanguage {
            XCTAssertEqual(calls, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testForeignRecoveryNeverReplacesValidPrimary() async throws {
        var calls = 0
        let result = try await WhisperTranscriber.decodeWithRecovery(audioData: [0.01], language: "en") { _, language, _ in
            calls += 1
            XCTAssertEqual(language, "en")
            return calls == 1 ? self.pass("Open the settings", weak: true, confidence: -1)
                : self.pass("Bonjour tout le monde", foreign: true, confidence: -0.1)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "Open the settings")
    }

    @MainActor
    func testLanguageDetectionChecksActualTextDespiteForcedTurkishMetadata() {
        for text in ["Það sem er neyndisvæmdir innan sig hérna.", "Das war der, den im Himmel der Katzenitsch auf.", "你好", "ПРИВЕТ"] {
            XCTAssertTrue(ForeignTranscriptGuard.requiresTurkishRetry(text, detectedLanguages: ["tr"],
                misheardCount: MisheardWordDetector.find(in: text).count), text)
        }
        for text in ["deploy et", "Selam", "Open the pull request and merge it", "José'ye yarın kafede buluşalım de", "Claude Code'da PR açar mısın"] {
            XCTAssertFalse(ForeignTranscriptGuard.requiresTurkishRetry(text, detectedLanguages: ["tr"],
                misheardCount: MisheardWordDetector.find(in: text).count), text)
        }
        XCTAssertTrue(ForeignTranscriptGuard.requiresTurkishRetry("ciao", detectedLanguages: ["it"], misheardCount: 0))
        XCTAssertFalse(ForeignTranscriptGuard.requiresTurkishRetry("", detectedLanguages: ["de"], misheardCount: 0))
    }
}
