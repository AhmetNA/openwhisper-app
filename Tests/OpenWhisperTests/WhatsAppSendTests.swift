import XCTest
@testable import OpenWhisper

@MainActor
final class WhatsAppSendTests: XCTestCase {
    func testMessageRequests() {
        XCTAssertEqual(WhatsAppSendParser.parse("Dilayım'a yaz: akşam geliyorum."),
                       WhatsAppOutgoing(recipient: "Dilayım", body: "Akşam geliyorum."))
        XCTAssertEqual(WhatsAppSendParser.parse("Hey Jarvis, Ali'ye mesaj at, yarın görüşürüz"),
                       WhatsAppOutgoing(recipient: "Ali", body: "Yarın görüşürüz"))
        XCTAssertEqual(WhatsAppSendParser.parse("Anneme WhatsApp'tan şunu yaz geç kalacağım"),
                       WhatsAppOutgoing(recipient: "Annem", body: "Geç kalacağım"))
        XCTAssertEqual(WhatsAppSendParser.parse("dilayıma mesaj gönder ki ekmek al"),
                       WhatsAppOutgoing(recipient: "Dilayım", body: "Ekmek al"))
        XCTAssertEqual(WhatsAppSendParser.parse("Akşam geliyorum diye Dilayım'a mesaj at"),
                       WhatsAppOutgoing(recipient: "Dilayım", body: "Akşam geliyorum"))
        XCTAssertEqual(WhatsAppSendParser.parse("dilayıma mesaj yaz"), WhatsAppOutgoing(recipient: "Dilayım", body: ""))
    }

    func testNotMessageRequests() {
        XCTAssertNil(WhatsAppSendParser.parse("Buraya yaz: merhaba"))
        XCTAssertNil(WhatsAppSendParser.parse("Bana yaz bunu"))
        XCTAssertNil(WhatsAppSendParser.parse("Claude Code'a yaz: testleri çalıştır"))
        XCTAssertNil(WhatsAppSendParser.parse("Ali ne yazdı"))
        XCTAssertNil(WhatsAppSendParser.parse("Bu akşam yazacağım"))
    }

    func testAnswers() {
        XCTAssertEqual(WhatsAppSender.decision("Evet."), .approve)
        XCTAssertEqual(WhatsAppSender.decision("Evet gönder"), .approve)
        XCTAssertEqual(WhatsAppSender.decision("Gönder lütfen"), .approve)
        XCTAssertEqual(WhatsAppSender.decision("Hayır."), .reject)
        XCTAssertEqual(WhatsAppSender.decision("Gönderme"), .reject)
        XCTAssertEqual(WhatsAppSender.decision("Vazgeçtim"), .reject)
        XCTAssertEqual(WhatsAppSender.decision("Evet ama önce şunu değiştir"), .unclear)
        XCTAssertEqual(WhatsAppSender.decision("Göndermesen daha iyi"), .unclear)
    }

    func testPhones() {
        let chat = WhatsAppStore.Chat(id: 1, name: "Ali", jid: "905551112233@s.whatsapp.net", unread: 0, isGroup: false, lastDate: nil)
        XCTAssertEqual(WhatsAppSender.phone(of: chat), "905551112233")
        let hidden = WhatsAppStore.Chat(id: 2, name: "Ali", jid: "123456789@lid", unread: 0, isGroup: false, lastDate: nil)
        XCTAssertNil(WhatsAppSender.phone(of: hidden))
        XCTAssertEqual(WhatsAppSender.phone(of: WhatsAppStore.Contact(fullName: "A", phones: ["05321112233"])), "905321112233")
        XCTAssertEqual(WhatsAppSender.phone(of: WhatsAppStore.Contact(fullName: "A", phones: ["5321112233"])), "905321112233")
        XCTAssertEqual(WhatsAppSender.phone(of: WhatsAppStore.Contact(fullName: "A", phones: ["0049301234567"])), "49301234567")
    }

    func testRoutes() {
        var facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .editable,
                                      hasTargetApp: true, targetBundleID: nil)
        guard case .whatsAppSend = VoiceRouter.route("Dilayım'a yaz: akşam geliyorum", facts: facts) else {
            return XCTFail("a message request is not dictation, even in a text field")
        }
        if case .whatsAppConfirmation = VoiceRouter.route("evet", facts: facts) {
            XCTFail("no message waits")
        }
        facts.pendingWhatsAppSend = true
        guard case .whatsAppConfirmation = VoiceRouter.route("evet", facts: facts) else {
            return XCTFail("a pending message gets the answer")
        }
    }
}
