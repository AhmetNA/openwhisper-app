import SQLite3
import XCTest
@testable import OpenWhisper

final class WhatsAppSearchTests: XCTestCase {
    func testTopicQuestions() {
        XCTAssertEqual(SystemCommandParser.parse("En son ne zaman kombi hakkında konuştuk?"),
                       .whatsAppSearch(topic: "kombi", person: nil))
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ta Dilay'la kombi hakkında ne konuşmuştuk"),
                       .whatsAppSearch(topic: "kombi", person: "Dilay"))
        XCTAssertEqual(SystemCommandParser.parse("Annemle bayram ile ilgili en son ne zaman konuştuk"),
                       .whatsAppSearch(topic: "bayram", person: "Annem"))
        XCTAssertEqual(SystemCommandParser.parse("Kombi ile ilgili en son ne konuştuk"),
                       .whatsAppSearch(topic: "kombi", person: nil))
        XCTAssertEqual(SystemCommandParser.parse("doğalgaz faturası geçen mesajları bul"),
                       .whatsAppSearch(topic: "doğalgaz faturası", person: nil))
        XCTAssertEqual(SystemCommandParser.parse("Mesajlarda kombi ara"), .whatsAppSearch(topic: "kombi", person: nil))
        // Without a topic it stays the plain last-conversation question.
        XCTAssertEqual(SystemCommandParser.parse("Dilayla en son ne konuştuk"), .whatsAppConversation("Dilay"))
    }

    func testRelatedWordsFromTheModel() {
        XCTAssertEqual(WhatsAppController.parseRelatedWords("petek, doğalgaz, Isıtma, servis, ev, petek"),
                       ["petek", "dogalgaz", "isitma", "servis"])
        XCTAssertEqual(WhatsAppController.parseRelatedWords("<think>x</think>\n- arıza\n- usta"), ["ariza", "usta"])
        XCTAssertEqual(WhatsAppController.parseRelatedWords("Isı, su, boru, baca, kazan"), ["boru", "baca", "kazan"])
    }

    func testDocumentsGoByNameOnly() {
        XCTAssertEqual(WhatsAppStore.readableText("", type: 8, fileName: "Kombi faturası.pdf"), "Belge: Kombi faturası.pdf")
        XCTAssertEqual(WhatsAppStore.readableText("caption", type: 8), "Belge")
        XCTAssertEqual(WhatsAppStore.readableText("caption", type: 2, fileName: "x.mp4"), "Video")
        XCTAssertEqual(WhatsAppStore.readableText("", type: 3, fileName: "ses.opus"), "Sesli mesaj")
    }

    func testSearchFindsWordStartsInTurkishSpelling() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER,
                ZTEXT TEXT, ZMESSAGEDATE REAL, ZMESSAGETYPE INTEGER, ZMEDIAITEM INTEGER);
            CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZMEDIALOCALPATH TEXT);
            INSERT INTO ZWAMEDIAITEM VALUES (1, NULL, 'Media/x/Kombi garanti.pdf');
            INSERT INTO ZWAMESSAGE VALUES (1, 1, 0, 'Kombiyi kim yaptırdı', 100, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (2, 2, 1, 'Ekombinezon', 200, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (3, 1, 0, 'ISITMA çalışmıyor', 300, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (4, 2, 0, NULL, 400, 8, 1);
            INSERT INTO ZWAMESSAGE VALUES (5, 1, 1, 'tamam', 500, 0, NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertEqual(try WhatsAppStore.search(["kombi"], limit: 10, at: url).map(\.text),
                       ["Belge: Kombi garanti.pdf", "Kombiyi kim yaptırdı"])
        XCTAssertEqual(try WhatsAppStore.search(["kombi"], chatID: 1, limit: 10, at: url).map(\.text), ["Kombiyi kim yaptırdı"])
        XCTAssertEqual(try WhatsAppStore.search(["isitma"], limit: 10, at: url).map(\.text), ["ISITMA çalışmıyor"])
        let around = try WhatsAppStore.messages(in: 1, from: Date(timeIntervalSinceReferenceDate: 150),
                                                to: Date(timeIntervalSinceReferenceDate: 600), limit: 10, at: url)
        XCTAssertEqual(around.map(\.text), ["tamam", "ISITMA çalışmıyor"])
    }
}
