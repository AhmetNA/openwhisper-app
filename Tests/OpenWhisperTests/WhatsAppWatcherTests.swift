import XCTest
@testable import OpenWhisper

@MainActor
final class WhatsAppWatcherTests: XCTestCase {
    private func chat(_ id: Int64, _ name: String, group: Bool = false, unread: Int = 1, archived: Bool = false) -> WhatsAppStore.Chat {
        WhatsAppStore.Chat(id: id, name: name, jid: "x", unread: unread, isGroup: group, lastDate: nil, isArchived: archived)
    }

    private func arrival(_ id: Int64, chat: Int64) -> WhatsAppStore.Arrival {
        WhatsAppStore.Arrival(messageID: id, chatID: chat, date: Date(), readable: true)
    }

    func testAblative() {
        XCTAssertEqual(WhatsAppWatcher.ablative("Dilayım"), "Dilayım'dan")
        XCTAssertEqual(WhatsAppWatcher.ablative("Mehmet"), "Mehmet'ten")
        XCTAssertEqual(WhatsAppWatcher.ablative("Ayşe"), "Ayşe'den")
        XCTAssertEqual(WhatsAppWatcher.ablative("Furkan"), "Furkan'dan")
        XCTAssertEqual(WhatsAppWatcher.ablative("Burak"), "Burak'tan")
        XCTAssertEqual(WhatsAppWatcher.ablative("Gül"), "Gül'den")
    }

    func testAnnouncements() {
        let chats = [chat(1, "Dilayım"), chat(2, "Ali"), chat(3, "Aile", group: true), chat(4, "Eski", archived: true),
                     chat(5, "Okundu", unread: 0), chat(6, "Mehmet")]
        XCTAssertEqual(WhatsAppWatcher.announcement(for: [arrival(10, chat: 1)], chats: chats),
                       .init(chatIDs: [1], text: "Dilayım'dan mesaj var, okuyayım mı?"))
        XCTAssertEqual(WhatsAppWatcher.announcement(for: [arrival(10, chat: 1), arrival(11, chat: 1)], chats: chats)?.text,
                       "Dilayım'dan 2 mesaj var, okuyayım mı?")
        XCTAssertEqual(WhatsAppWatcher.announcement(for: [arrival(10, chat: 1), arrival(11, chat: 2)], chats: chats),
                       .init(chatIDs: [2, 1], text: "Ali ve Dilayım'dan mesaj var, okuyayım mı?"))
        XCTAssertEqual(WhatsAppWatcher.announcement(for: [arrival(10, chat: 1), arrival(11, chat: 2), arrival(12, chat: 6)], chats: chats)?.text,
                       "3 kişiden yeni mesaj var, okuyayım mı?")
        XCTAssertNil(WhatsAppWatcher.announcement(for: [arrival(10, chat: 3), arrival(11, chat: 4), arrival(12, chat: 5)], chats: chats))
    }

    func testMissedWhileLocked() {
        let chats = [chat(1, "Dilayım", unread: 3), chat(2, "Ali", unread: 0), chat(3, "Aile", group: true), chat(6, "Mehmet")]
        XCTAssertEqual(WhatsAppWatcher.missedAnnouncement([1, 2], chats: chats),
                       .init(chatIDs: [1], text: "Sen yokken Dilayım'dan 3 mesaj var, okuyayım mı?"))
        XCTAssertEqual(WhatsAppWatcher.missedAnnouncement([6, 1], chats: chats)?.text,
                       "Sen yokken Mehmet ve Dilayım'dan mesaj var, okuyayım mı?")
        XCTAssertNil(WhatsAppWatcher.missedAnnouncement([2, 3], chats: chats))
    }

    func testAnnouncementVolume() {
        let gain = { (system: Float?, headphones: Bool) in JarvisVoice.announcementVolume(systemVolume: system, headphones: headphones) }
        XCTAssertEqual(gain(0.8, true), JarvisVoice.replyVolume)
        // Heard level = system × gain: 80% → 40%, 100% → 50%, 30% → 20% floor, 10% → only 10%.
        XCTAssertEqual(0.8 * gain(0.8, false), 0.4, accuracy: 0.001)
        XCTAssertEqual(1.0 * gain(1.0, false), 0.5, accuracy: 0.001)
        XCTAssertEqual(0.3 * gain(0.3, false), 0.2, accuracy: 0.001)
        XCTAssertEqual(gain(0.1, false), 1, accuracy: 0.001)
        XCTAssertEqual(gain(nil, false), JarvisVoice.replyVolume)
    }

    func testReadAnswers() {
        XCTAssertEqual(WhatsAppSender.readDecision("Evet, oku."), .approve)
        XCTAssertEqual(WhatsAppSender.readDecision("Oku"), .approve)
        XCTAssertEqual(WhatsAppSender.readDecision("Ne yazmış?"), .approve)
        XCTAssertEqual(WhatsAppSender.readDecision("Sonra"), .reject)
        XCTAssertEqual(WhatsAppSender.readDecision("Hayır"), .reject)
        XCTAssertEqual(WhatsAppSender.readDecision("Dilayım'a yaz: geliyorum"), .unclear)
    }

    func testArrivalsFromFixture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sql = """
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER,
                ZTEXT TEXT, ZMESSAGEDATE REAL, ZMESSAGETYPE INTEGER);
            INSERT INTO ZWAMESSAGE VALUES (1, 1, 0, 'eski', 0, 0);
            INSERT INTO ZWAMESSAGE VALUES (2, 1, 1, 'benden', 0, 0);
            INSERT INTO ZWAMESSAGE VALUES (3, 1, 0, 'selam', 0, 0);
            INSERT INTO ZWAMESSAGE VALUES (4, 2, 0, '{"x":1}', 0, 6);
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try WhatsAppStore.newestMessageID(at: url), 4)
        let arrivals = try WhatsAppStore.arrivals(after: 1, at: url)
        XCTAssertEqual(arrivals.map(\.messageID), [3, 4])
        XCTAssertEqual(arrivals.map(\.readable), [true, false])
    }
}
