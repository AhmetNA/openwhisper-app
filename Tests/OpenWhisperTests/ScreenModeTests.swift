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
}
