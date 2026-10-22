import SQLite3
import XCTest
@testable import OpenWhisper

final class WhatsAppTests: XCTestCase {
    // MARK: - Parsing

    func testSenderQuestions() {
        XCTAssertEqual(SystemCommandParser.parse("Ali ne yazdı?"), .whatsAppFrom("Ali"))
        XCTAssertEqual(SystemCommandParser.parse("Hey Jarvis, Ayşe ne demiş"), .whatsAppFrom("Ayşe"))
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ta Ahmet abi ne yazmış"), .whatsAppFrom("Ahmet Abi"))
        XCTAssertEqual(SystemCommandParser.parse("Annem bana ne yazdı"), .whatsAppFrom("Annem"))
        XCTAssertEqual(SystemCommandParser.parse("Mehmet'ten mesaj var mı"), .whatsAppFrom("Mehmet"))
        XCTAssertEqual(SystemCommandParser.parse("İremden yeni mesaj geldi mi"), .whatsAppFrom("İrem"))
        XCTAssertEqual(SystemCommandParser.parse("Metin'in mesajını oku"), .whatsAppFrom("Metin"))
    }

    func testUnreadQuestions() {
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ta okunmamış var mı"), .whatsAppUnread)
        XCTAssertEqual(SystemCommandParser.parse("Okunmamış mesajları oku"), .whatsAppUnread)
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ta yeni mesaj var mı"), .whatsAppUnread)
        XCTAssertEqual(SystemCommandParser.parse("Kim yazdı?"), .whatsAppUnread)
        XCTAssertEqual(SystemCommandParser.parse("Yeni mesajım var mı"), .whatsAppUnread)
    }

    func testNotWhatsApp() {
        XCTAssertEqual(SystemCommandParser.parse("Ahmet'ten mail var mı"), .mailFrom("Ahmet"))
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ı aç", installedApps: ["WhatsApp"]), .openApp("WhatsApp"))
        XCTAssertNil(SystemCommandParser.parse("Claude ne yazdı"))
        XCTAssertNil(SystemCommandParser.parse("O ne demiş"))
        XCTAssertNil(SystemCommandParser.parse("Okunmamış mailleri oku").flatMap { $0 == .whatsAppUnread ? $0 : nil })
    }

    // MARK: - Matching

    private func chat(_ id: Int64, _ name: String, jid: String = "", group: Bool = false, last: TimeInterval = 0) -> WhatsAppStore.Chat {
        WhatsAppStore.Chat(id: id, name: name, jid: jid.isEmpty ? "90555000000\(id)@s.whatsapp.net" : jid,
                           unread: 0, isGroup: group, lastDate: Date(timeIntervalSinceReferenceDate: last))
    }

    func testBestChat() {
        let chats = [
            chat(1, "Ali Veli", last: 100),
            chat(2, "Ali", last: 50),
            chat(3, "Ali'nin doğum günü", group: true, last: 200),
            chat(4, "Ayşe Yılmaz", last: 10),
            chat(5, "Metin Kaya", last: 5),
        ]
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Ali", in: chats)?.chat.id, 2)
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Ali", in: chats)?.others, 2)
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Ali Veli", in: chats)?.chat.id, 1)
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Ayse", in: chats)?.chat.id, 4)
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Meti", in: chats)?.chat.id, 5)
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Metinin", in: chats)?.chat.id, 5)
        XCTAssertNil(WhatsAppStore.bestChat(for: "Zeynep", in: chats))
    }

    func testBestChatThroughContacts() {
        let chats = [chat(1, "Anne", jid: "905321112233@s.whatsapp.net"), chat(2, "Annemarie")]
        let mom = WhatsAppStore.Contact(fullName: "Fatma Yılmaz", phones: ["05321112233"])
        XCTAssertEqual(WhatsAppStore.bestChat(for: "Fatma", in: chats, contacts: [mom])?.chat.id, 1)
    }

    // MARK: - Reading the database

    func testReadsFixtureDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZPARTNERNAME TEXT, ZCONTACTJID TEXT,
                ZUNREADCOUNT INTEGER, ZSESSIONTYPE INTEGER, ZLASTMESSAGEDATE REAL, ZREMOVED INTEGER);
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER,
                ZTEXT TEXT, ZMESSAGEDATE REAL, ZMESSAGETYPE INTEGER, ZGROUPMEMBER INTEGER);
            CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCONTACTNAME TEXT, ZFIRSTNAME TEXT);
            INSERT INTO ZWACHATSESSION VALUES (1, 'Ali', '905551112233@s.whatsapp.net', 2, 0, 300, 0);
            INSERT INTO ZWACHATSESSION VALUES (2, 'Aile', '1203630@g.us', 0, 1, 200, 0);
            INSERT INTO ZWACHATSESSION VALUES (3, '', 'status@broadcast', 5, 3, 400, 0);
            INSERT INTO ZWAGROUPMEMBER VALUES (1, 'Annem', NULL);
            INSERT INTO ZWAMESSAGE VALUES (1, 1, 1, 'Naber', 100, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (2, 1, 0, 'İyi, sen?', 200, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (3, 1, 0, NULL, 300, 3, NULL);
            INSERT INTO ZWAMESSAGE VALUES (4, 2, 0, '{"is_hidden_sub_group":false}', 150, 6, NULL);
            INSERT INTO ZWAMESSAGE VALUES (6, 2, 0, '{"linked_groups":[]}', 160, 0, NULL);
            INSERT INTO ZWAMESSAGE VALUES (5, 2, 0, 'Yemek hazır', 200, 0, 1);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let chats = try WhatsAppStore.chats(at: url)
        XCTAssertEqual(chats.map(\.name), ["Ali", "Aile"])
        XCTAssertEqual(chats.first?.unread, 2)
        XCTAssertEqual(chats.last?.isGroup, true)

        let ali = try WhatsAppStore.messages(in: 1, limit: 5, at: url)
        XCTAssertEqual(ali.map(\.text), ["Sesli mesaj", "İyi, sen?", "Naber"])
        XCTAssertEqual(ali.map(\.fromMe), [false, false, true])

        let family = try WhatsAppStore.messages(in: 2, limit: 5, at: url)
        XCTAssertEqual(family.map(\.text), ["Yemek hazır"])
        XCTAssertEqual(family.first?.sender, "Annem")
    }

    func testOnlyTextAndMediaAreRead() {
        XCTAssertEqual(WhatsAppStore.readableText("Selam", type: 0), "Selam")
        XCTAssertEqual(WhatsAppStore.readableText("https://x.com", type: 7), "https://x.com")
        XCTAssertNil(WhatsAppStore.readableText("{\"is_hidden_sub_group\":false}", type: 6))
        XCTAssertNil(WhatsAppStore.readableText("{\"a\":1}", type: 0))
        XCTAssertNil(WhatsAppStore.readableText("Ali gruba katıldı", type: 6))
        XCTAssertEqual(WhatsAppStore.readableText("caption", type: 1), "Fotoğraf")
        XCTAssertNil(WhatsAppStore.readableText("", type: 0))
    }

    func testMissingFolderIsNotInstalled() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/ChatStorage.sqlite")
        XCTAssertThrowsError(try WhatsAppStore.chats(at: url)) { error in
            XCTAssertEqual(error as? WhatsAppStore.Failure, .notInstalled)
        }
    }
}
