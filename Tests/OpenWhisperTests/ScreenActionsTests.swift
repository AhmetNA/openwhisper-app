import XCTest
@testable import OpenWhisper

final class ScreenActionsTests: XCTestCase {
    private let labels = ["Kaydet", "İptal", "İzin Ver", "Tamam", "Gönder", "Yeni Klasör", "Ara"]

    func testLabelSaidAsWritten() {
        XCTAssertEqual(ScreenActions.exactMatches("Kaydet.", labels: labels), [0])
        XCTAssertEqual(ScreenActions.exactMatches("Kaydet'e bas", labels: labels), [0])
        XCTAssertEqual(ScreenActions.exactMatches("kaydete tıklar mısın", labels: labels), [0])
        XCTAssertEqual(ScreenActions.exactMatches("izin ver", labels: labels), [2])
        XCTAssertEqual(ScreenActions.exactMatches("Tamam'a tıkla lütfen", labels: labels), [3])
        XCTAssertEqual(ScreenActions.exactMatches("yeni klasör butonuna bas", labels: labels), [5])
        XCTAssertEqual(ScreenActions.exactMatches("Kaydet", labels: ["Kaydet", "Kaydet"]), [0, 1])
        XCTAssertEqual(ScreenActions.exactMatches("kaydet ve kapat", labels: labels), [])
    }

    func testOnlyScreenTalkAsksTheModel() {
        XCTAssertTrue(ScreenActions.mayBeAboutScreen("sağ üstteki çarpıya bas", labels: labels))
        XCTAssertTrue(ScreenActions.mayBeAboutScreen("klasörü yenisini oluştur", labels: labels))
        XCTAssertFalse(ScreenActions.mayBeAboutScreen("bana bir fıkra anlat", labels: labels))
        XCTAssertTrue(ScreenActions.worthLooking("Kaydet"))
        XCTAssertTrue(ScreenActions.worthLooking("şu mavi butona bas"))
        XCTAssertFalse(ScreenActions.worthLooking("yarın hava nasıl olacak?"))
        XCTAssertFalse(ScreenActions.worthLooking("bugün akşam yemeğinde ne pişirsem acaba hiç fikrim yok"))
    }

    func testClickSaidOutright() {
        XCTAssertTrue(ScreenActions.saysClick("Gönder'e tıkla"))
        XCTAssertTrue(ScreenActions.saysClick("gönder butonuna bas"))
        XCTAssertFalse(ScreenActions.saysClick("tamam"))
        XCTAssertFalse(ScreenActions.saysClick("yarın basına bakarız"))
    }

    func testRiskyLabels() {
        for label in ["Sil", "Gönder", "Satın Al", "Delete", "Sign Out", "Kaydetme", "Ödeme Yap", "Send"] {
            XCTAssertTrue(ScreenActions.isRisky(label), label)
        }
        for label in ["Kaydet", "İptal", "Tamam", "İzin Ver", "Yeni Klasör", "Kapat"] {
            XCTAssertFalse(ScreenActions.isRisky(label), label)
        }
    }

    func testConfirmationAnswers() {
        XCTAssertEqual(ScreenActions.confirmation("Evet."), true)
        XCTAssertEqual(ScreenActions.confirmation("evet bas"), true)
        XCTAssertEqual(ScreenActions.confirmation("Hayır"), false)
        XCTAssertEqual(ScreenActions.confirmation("vazgeç"), false)
        XCTAssertNil(ScreenActions.confirmation("Safari'ye geç"))
    }

    func testModelAnswer() {
        XCTAssertEqual(ScreenActions.parsePick("3", count: 5), 2)
        XCTAssertEqual(ScreenActions.parsePick(" 5.", count: 5), 4)
        XCTAssertNil(ScreenActions.parsePick("YOK", count: 5))
        XCTAssertNil(ScreenActions.parsePick("9", count: 5))
    }

    func testRegion() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 600)
        XCTAssertEqual(ScreenActions.region(of: CGRect(x: 960, y: 110, width: 20, height: 20), in: window), "sağ üst")
        XCTAssertEqual(ScreenActions.region(of: CGRect(x: 520, y: 380, width: 60, height: 20), in: window), "orta")
        XCTAssertEqual(ScreenActions.region(of: CGRect(x: 110, y: 660, width: 60, height: 20), in: window), "sol alt")
    }

    func testUndoInverses() {
        XCTAssertEqual(CommandUndo.steps(undoing: [.system(.wifi(on: false)), .system(.mute(true))]),
                       [.system(.mute(false)), .system(.wifi(on: true))])
        XCTAssertEqual(CommandUndo.steps(undoing: [.system(.quitApp("Safari"))]), [.system(.openApp("Safari"))])
        XCTAssertEqual(CommandUndo.steps(undoing: [.system(.openApp("Safari")), .system(.time)]), [])
    }

    func testMetaPhrases() {
        XCTAssertEqual(JarvisReply.meta(in: "Burada ne diyebilirim?"), .whatCanISay)
        XCTAssertEqual(JarvisReply.meta(in: "Jarvis, ne duydun?"), .whatDidYouHear)
        XCTAssertEqual(JarvisReply.meta(in: "Son komutu geri al."), .undoLastCommand)
        XCTAssertEqual(JarvisReply.meta(in: "Ne yapabilirsin?"), .help)
    }
}
