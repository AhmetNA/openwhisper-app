import XCTest
@testable import OpenWhisper

@MainActor
final class EnglishWhatsAppTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    private func chat(_ id: Int64, _ name: String, group: Bool = false, unread: Int = 1) -> WhatsAppStore.Chat {
        WhatsAppStore.Chat(id: id, name: name, jid: "x", unread: unread, isGroup: group, lastDate: nil, isArchived: false)
    }

    func testNotice() {
        XCTAssertEqual(WhatsAppController.notice(for: [chat(1, "Ali", unread: 2), chat(2, "Ayşe"), chat(3, "Aile", group: true, unread: 4)]),
                       "WhatsApp · 7 messages · 2 people, 1 group\nAli, Ayşe, Aile")
        XCTAssertEqual(WhatsAppController.notice(for: [chat(1, "Ali")]), "WhatsApp · 1 message from Ali")
        XCTAssertEqual(WhatsAppController.notice(for: [chat(3, "Aile", group: true, unread: 5)]), "WhatsApp · 5 messages in Aile")
    }

    func testAnnouncement() {
        let arrivals = [WhatsAppStore.Arrival(messageID: 10, chatID: 1, date: Date(), readable: true),
                        WhatsAppStore.Arrival(messageID: 11, chatID: 1, date: Date(), readable: true)]
        XCTAssertEqual(WhatsAppWatcher.announcement(for: arrivals, chats: [chat(1, "Ali")])?.text,
                       "2 messages from Ali, shall I read them?")
    }

    func testMediaAndLinks() {
        XCTAssertEqual(WhatsAppStore.mediaLabel(3), "Voice message")
        XCTAssertEqual(WhatsAppController.spokenLinks("https://example.com"), "sent a new link")
        XCTAssertEqual(WhatsAppController.spokenLinks("look https://example.com"), "look a link")
    }
}
