import XCTest
@testable import OpenWhisper

final class JarvisAddresseeTests: XCTestCase {

    func testTrailingYazVariants() {
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Bluetooth'u kapat yaz"), "Bluetooth'u kapat")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Akşam geliyorum, bunu yaz."), "Akşam geliyorum")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("toplantı üçte yaz bunu"), "toplantı üçte")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Tamam hocam hallederim yazsana"), "Tamam hocam hallederim")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Yarın gelirim yazar mısın?"), "Yarın gelirim")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("selam naber ve yaz!"), "selam naber")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Selam naber. Yaz."), "Selam naber")
    }

    func testSeasonYazIsNotACommand() {
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Tatile gideceğiz bu yaz"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("çok sıcaktı geçen yaz."))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Taşınacağız gelecek yaz"))
    }

    func testNoTrailingYaz() {
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("şarkının sözlerini yazdım"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("yaz bana bir şiir"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("kara deliği anlat"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("yaz"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Bu Ayaz"))
    }

    func testParseScore() {
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": 85}"#), 85)
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": "40"}"#), 40)
        XCTAssertEqual(JarvisAddressee.parseScore(" 72 "), 72)
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": 140}"#), 100)
        XCTAssertNil(JarvisAddressee.parseScore("evet"))
        XCTAssertNil(JarvisAddressee.parseScore(#"{"answer": 3}"#))
    }

    func testDecisionFavoursTyping() {
        XCTAssertTrue(JarvisAddressee.isForJarvis(score: 80, minScore: 70))
        XCTAssertTrue(JarvisAddressee.isForJarvis(score: 70, minScore: 70))
        XCTAssertFalse(JarvisAddressee.isForJarvis(score: 50, minScore: 70))
        XCTAssertFalse(JarvisAddressee.isForJarvis(score: nil, minScore: 70))
    }
}
