import XCTest
@testable import OpenWhisper

final class ScreenModeTests: XCTestCase {
    func testClosers() {
        XCTAssertTrue(ScreenMode.isCloser("Tamamdır."))
        XCTAssertTrue(ScreenMode.isCloser("harikasın Jarvis"))
        XCTAssertTrue(ScreenMode.isCloser("bu kadar"))
        XCTAssertTrue(ScreenMode.isCloser("Teşekkürler!"))
    }

    func testButtonsAndAnswersAreNoClosers() {
        XCTAssertFalse(ScreenMode.isCloser("Tamam"))
        XCTAssertFalse(ScreenMode.isCloser("Tamam'a bas"))
        XCTAssertFalse(ScreenMode.isCloser("Bitti"))
        XCTAssertFalse(ScreenMode.isCloser("tamamdır şimdi kaydet'e bas"))
    }

    func testTypeAndSend() {
        XCTAssertEqual(ScreenMode.typeRequest("merhaba nasılsın yaz ve gönder")?.text, "merhaba nasılsın")
        XCTAssertEqual(ScreenMode.typeRequest("merhaba nasılsın yaz ve gönder")?.send, true)
        XCTAssertEqual(ScreenMode.typeRequest("yarın geliyorum diye yazıp gönder")?.text, "yarın geliyorum")
        XCTAssertEqual(ScreenMode.typeRequest("kedi videoları yaz")?.text, "kedi videoları")
        XCTAssertEqual(ScreenMode.typeRequest("kedi videoları yaz")?.send, false)
        XCTAssertEqual(ScreenMode.typeRequest("buraya şunu yaz toplantı saat üçte")?.text, "toplantı saat üçte")
    }

    func testPressesAreNotTyping() {
        XCTAssertNil(ScreenMode.typeRequest("Gönder'e bas"))
        XCTAssertNil(ScreenMode.typeRequest("gönder"))
        XCTAssertNil(ScreenMode.typeRequest("aşağı kaydır"))
    }

    func testFinishedPresses() {
        XCTAssertTrue(ScreenMode.isFinishedPress("Software update'e bas."))
        XCTAssertTrue(ScreenMode.isFinishedPress("geri butonuna bas lütfen"))
        XCTAssertTrue(ScreenMode.isFinishedPress("Kaydet'e tıkla"))
        XCTAssertTrue(ScreenMode.isFinishedPress("Gönder'e basar mısın?"))
    }

    func testUnfinishedOrTypingIsNoFinishedPress() {
        XCTAssertFalse(ScreenMode.isFinishedPress("geri butonuna"))
        XCTAssertFalse(ScreenMode.isFinishedPress("merhaba yaz ve gönder"))
        XCTAssertFalse(ScreenMode.isFinishedPress("bas yaz"))
        XCTAssertFalse(ScreenMode.isFinishedPress("aşağı kaydır"))
    }

    func testTypeIntoAField() {
        let search = ScreenMode.fieldTypeRequest("arama kısmına kedi videoları yaz")
        XCTAssertEqual(search?.field, "arama")
        XCTAssertEqual(search?.text, "kedi videoları")
        XCTAssertEqual(search?.send, true)
        let message = ScreenMode.fieldTypeRequest("Jarvis mesaj kutusuna yarın geliyorum diye yaz")
        XCTAssertEqual(message?.field, "mesaj")
        XCTAssertEqual(message?.text, "yarın geliyorum")
        XCTAssertEqual(message?.send, false)
        XCTAssertEqual(ScreenMode.fieldTypeRequest("adres çubuğuna youtube.com yaz ve gönder")?.send, true)
        XCTAssertNil(ScreenMode.fieldTypeRequest("kedi videoları yaz"))
    }

    func testRepeatPress() {
        XCTAssertTrue(ScreenMode.isRepeat("tekrar bas"))
        XCTAssertTrue(ScreenMode.isRepeat("bir daha mikrofona bas"))
        XCTAssertFalse(ScreenMode.isRepeat("mikrofona bas"))
    }
}
