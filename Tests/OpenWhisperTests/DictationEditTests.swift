import XCTest
@testable import OpenWhisper

final class DictationEditTests: XCTestCase {
    private let dictation = "Yarın Ahmed ile toplantı var. Saat üçte buluşuruz"

    private func edited(_ spoken: String, _ text: String? = nil) -> String? {
        let text = text ?? dictation
        return DictationEdit.parse(spoken, dictation: text)?.applied(to: text)
    }

    func testDeletePhrases() {
        for spoken in ["Sil.", "bunu sil", "Geri al", "Son yazdığımı sil!"] {
            XCTAssertEqual(DictationEdit.parse(spoken, dictation: dictation), .deleteAll, spoken)
        }
        XCTAssertEqual(edited("sil"), "")
        XCTAssertEqual(edited("Son kelimeyi sil."), "Yarın Ahmed ile toplantı var. Saat üçte")
        XCTAssertEqual(edited("son cümleyi sil"), "Yarın Ahmed ile toplantı var.")
        XCTAssertEqual(edited("son cümleyi sil", "Tek cümle."), "")
    }

    func testReturn() {
        for spoken in ["Enter.", "Enter'a bas", "Entere bas", "enter tuşuna bas"] {
            XCTAssertEqual(DictationEdit.parse(spoken, dictation: dictation), .pressReturn, spoken)
            XCTAssertTrue(DictationEdit.isReturn(spoken), spoken)
        }
    }

    func testReplaceForms() {
        let expected = "Yarın Ahmet ile toplantı var. Saat üçte buluşuruz"
        XCTAssertEqual(edited("Ahmed'i Ahmet yap"), expected)
        XCTAssertEqual(edited("Ahmedi Ahmet yap."), expected)
        XCTAssertEqual(edited("Ahmed yerine Ahmet yaz"), expected)
        XCTAssertEqual(edited("Ahmed'i Ahmet olarak düzelt"), expected)
        XCTAssertEqual(edited("ahmedi ahmet ile değiştir"), expected)
        XCTAssertEqual(edited("Saat üçte'yi saat dörtte yap"), "Yarın Ahmed ile toplantı var. Saat dörtte buluşuruz")
    }

    func testSoftenedStemIsFound() {
        // Whisper wrote the softened form; the spoken accusative finds the hard one.
        XCTAssertEqual(edited("kitabı defter yap", "Kitap masada"), "Defter masada")
        XCTAssertEqual(edited("Ahmedi Mehmet yap", "Ahmet geldi"), "Mehmet geldi")
    }

    func testMultiWordAndEveryOccurrence() {
        XCTAssertEqual(edited("Ahmet Yılmaz'ı Mehmet Yıldız yap", "Ahmet Yılmaz aradı, Ahmet Yılmaz'a dön"),
                       "Mehmet Yıldız aradı, Mehmet Yıldız'a dön")
    }

    func testNotAnEdit() {
        for spoken in ["bunu daha iyi yap", "raporu hazır yap", "şunu kırmızı yap", "silgi aldım",
                       "videoyu biraz geri al", "yarın hatırlatıcısını sil", "toplantıyı yarın yap ve haber ver bana lütfen hemen şimdi"] {
            XCTAssertNil(DictationEdit.parse(spoken, dictation: dictation), spoken)
        }
        // Only whole words: "üç" is not in "üçte".
        XCTAssertNil(DictationEdit.parse("medi Mehmet yap", dictation: "Ahmed geldi"))
        XCTAssertNil(DictationEdit.parse("üçü dört yap", dictation: dictation))
    }
}
