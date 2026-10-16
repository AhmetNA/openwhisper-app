import XCTest
@testable import OpenWhisper

@MainActor
final class ForeignTranscriptGuardTests: XCTestCase {
    private func isForeign(_ text: String) -> Bool {
        ForeignTranscriptGuard.isForeign(text, misheardCount: MisheardWordDetector.find(in: text, ignoring: []).count)
    }

    func testBlocksWhisperOutputFromGarbledBudsRecordings() {
        XCTAssertTrue(isForeign("Það sem er neyndisvæmdir innan sig hérna."))
        XCTAssertTrue(isForeign("Das war der, den im Himmel der Katzenitsch auf."))
        XCTAssertTrue(isForeign("Das war der Benung, nehmlich hat sie mit. Ciao."))
        XCTAssertTrue(isForeign("Bonjour, comment ça va? Je ne sais pas."))
    }

    func testKeepsTurkishAndEnglish() {
        for text in [
            "Spotify'da benim memleketim inşallah.",
            "Çok fayda benim memleketim için.",
            "Claude Code'da PR açar mısın, merge etmeden önce test et.",
            "open the pull request and merge it",
            "Hey Jarvis, Spotify'da Tarkan çal",
            "Yarın saat 9'da toplantı var",
            "José'ye yarın kafede buluşalım de",
        ] {
            XCTAssertFalse(isForeign(text), text)
        }
    }

    func testShortTextIsNeverJudgedByLanguageID() {
        for text in ["deploy et", "Selam", "Ne?", "Ok", "Hmm", "Evet."] {
            XCTAssertFalse(isForeign(text), text)
        }
    }
}
