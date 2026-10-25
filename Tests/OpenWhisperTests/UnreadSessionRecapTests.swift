import XCTest
@testable import OpenWhisper

final class UnreadSessionRecapTests: XCTestCase {
    func testNewChatCannotBeMistakenForIncomingReplies() {
        for text in ["harika o zaman gelin sohbet aç kodekste", "Gelin sohbet aç", "Codex'te yeni sohbet aç", "Harika, o zaman yeni sohbet aç Codex'te"] {
            XCTAssertTrue(CloudSessionNavigation.isNewChatRequest(text), text)
            XCTAssertFalse(UnreadSessionRecap.isRequest(text), text)
            XCTAssertNil(UnreadSessionRecap.selection(text), text)
        }
        for text in ["Yeni sohbet açma", "Claude'a yeni sohbet aç diye yaz", "Yeni sohbet aç özelliğini ekle"] {
            XCTAssertFalse(CloudSessionNavigation.isNewChatRequest(text), text)
        }
    }

    func testReadRecentAndCurrentSessionsWithoutUnreadMarkers() {
        for text in ["Codex'te son oturumu özetle", "ChatGPT son cevabı oku", "Claude Code'da son mesajı oku", "Son cevabı oku", "Claude son yanıtı okur musun", "Codex son oturumu anlatır mısın"] {
            XCTAssertEqual(UnreadSessionRecap.selection(text), .latest, text)
        }
        for text in ["Bu sohbeti özetle", "Claude'da açık oturumu oku", "Mevcut sohbetin son yanıtını oku"] {
            XCTAssertEqual(UnreadSessionRecap.selection(text), .current, text)
        }
        for text in ["Son cevabı okuma", "Claude'a son cevabı oku diye yaz", "Son cevabı oku özelliğini ekle"] {
            XCTAssertNil(UnreadSessionRecap.selection(text), text)
        }
    }

    func testCommandsAndNegation() {
        for text in ["cevap gelen chatleri aç", "cevap gelen sessionleri aç", "Claude Code'da yanıt gelen oturumları aç", "ChatGPT'deki okunmamış sohbetleri özetle"] {
            XCTAssertTrue(UnreadSessionRecap.isRequest(text), text)
        }
        for text in ["cevap gelen chatleri açma", "Claude'a cevap gelen chatleri aç özelliğini yaz", "yeni chat aç", "cevap gelen chatleri aç dediğimde çalışsın istiyorum"] {
            XCTAssertFalse(UnreadSessionRecap.isRequest(text), text)
        }
        XCTAssertEqual(UnreadSessionRecap.target("Claude'da cevap gelen chatleri aç", frontBundleID: "com.openai.codex"), .claudeCode)
        XCTAssertEqual(UnreadSessionRecap.target("cevap gelen chatleri aç", frontBundleID: "com.openai.codex"), .chatGPT)
        XCTAssertNil(UnreadSessionRecap.target("cevap gelen chatleri aç", frontBundleID: "com.apple.Safari"))
    }
    func testNaturalReplyRequestsWithoutFixedWordOrder() {
        let examples = [
            "Hangi sohbetlere cevap gelmiş?", "Yeni yanıtları oku", "Bitmiş sohbetleri göster",
            "yeni gelen yanıtları aç", "chatgptdene yeni tyanıtları aç",
            "ChatGPT'den yeni yanıtları aç", "sohbetlerden neler gelmiş açıkla",
            "Sohbetlere ne gelmiş?", "ChatGPT'deki sohbetlere gelenleri anlat",
            "Jarvis bana yeni gelen cevapları kısaca anlatır mısın?",
            "ChatGPT'de cevap gelmiş mi?", "Claude Code'da hangi işler değil hangi sohbetler bitmiş?",
            "Cevaplanmış oturumlara geç", "Yanıtlanan chatleri açabilir misin?",
            "Okumadığım yanıtları özetler misin?", "Bakmadığım sohbetleri getir",
            "Görmediğim yeni cevaplar var mı?", "Cevapları yeni gelen sessionları aç",
            "Claude ne cevap vermiş?", "ChatGPT'den yeni ne yanıt gelmiş?",
            "Tamamlanan oturumları bir açsana", "Cevap gelen sohbetleri açmanı istiyorum",
            "Yeni cevapların özetini duymak istiyorum", "Yeni yanıtları okumak istiyorum",
            "Okunmamış mesajları söyle", "yeni yanitlari ozetle", "Cevabı hazır olan sohbetlere bak",
            "Lütfen Claude Code'daki henüz okumadığım yeni yanıtları bana çok kısa bir şekilde anlatabilir misin?",
        ]
        for text in examples { XCTAssertTrue(UnreadSessionRecap.isRequest(text), text) }
    }

    func testNaturalRequestsDoNotStealOtherCommandsOrNegations() {
        let examples = [
            "Yeni yanıtları okuma", "Yeni yanıtları okumak istemiyorum",
            "Bitmiş sohbetleri gösterme", "Cevap gelen sohbetleri açmak istemiyorum",
            "Yeni yanıtları açmaya gerek yok", "Okunmamış sohbetleri boş ver",
            "WhatsApp'ta yeni cevapları oku", "Maildeki yeni yanıtları özetle",
            "Yeni sohbet aç", "Son cevabı oku", "Hava durumunu anlat",
            "Claude'a yeni yanıtları oku diye yaz", "Cevap gelen chatleri aç dersem çalışsın",
            "Okunmamış sohbet özelliğini ekle", "Yeni yanıtları okuma özelliği nasıl çalışır?",
            "Yeni mesaj yaz", "Sohbetlere cevap gelmesini bekliyorum",
            "Sohbetlerden neler gelmiş açıklama",
        ]
        for text in examples { XCTAssertFalse(UnreadSessionRecap.isRequest(text), text) }
        XCTAssertEqual(UnreadSessionRecap.target("Çet GPT'de yeni yanıtları oku", frontBundleID: nil), .chatGPT)
        XCTAssertEqual(UnreadSessionRecap.target("Klaud'da bitmiş sohbetleri göster", frontBundleID: nil), .claudeCode)
    }

    @MainActor
    func testActualRecordedReplyReachesSendRouteForBothApps() {
        let text = "Harikasın, süper olmuş ve çok iyi çalışıyor. Teşekkürler, gönder."
        for (bundle, app) in [("com.openai.codex", AgentApp.chatGPT), ("com.anthropic.claudefordesktop", .claudeCode)] {
            let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                          focus: .editable, hasTargetApp: true, targetBundleID: bundle)
            guard case .agent(let request) = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Explicit send must route to the conversation: \(bundle)")
                continue
            }
            XCTAssertEqual(request.body, "Harikasın, süper olmuş ve çok iyi çalışıyor. Teşekkürler")
            XCTAssertTrue(UnreadSessionRecap.allowsReplySend(request, isRecap: true,
                expectedID: "recap", capturedID: "recap", capturedAgent: app))
        }
    }

    func testExplicitSendAfterRecapIsAllowedOnlyForThatConversation() throws {
        let request = try XCTUnwrap(AgentCommandParser.parse("Harikasın, süper olmuş ve çok iyi çalışıyor. Teşekkürler, gönder."))
        XCTAssertTrue(request.send)
        XCTAssertFalse(request.body.lowercased().contains("gönder"))
        for app in [AgentApp.chatGPT, .claudeCode] {
            XCTAssertTrue(UnreadSessionRecap.allowsReplySend(request, isRecap: true, expectedID: "recapped", capturedID: "recapped", capturedAgent: app))
        }
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(request, isRecap: false, expectedID: "recapped", capturedID: "recapped", capturedAgent: .chatGPT))
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(request, isRecap: true, expectedID: "recapped", capturedID: "other", capturedAgent: .chatGPT))
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(request, isRecap: true, expectedID: "recapped", capturedID: nil, capturedAgent: nil))
        let unsent = AgentDictation(target: nil, body: "Harikasın", send: false)
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(unsent, isRecap: true, expectedID: "recapped", capturedID: "recapped", capturedAgent: .chatGPT))
        let otherApp = AgentDictation(target: .claudeCode, body: "Harikasın", send: true)
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(otherApp, isRecap: true, expectedID: "recapped", capturedID: "recapped", capturedAgent: .chatGPT))
        let anotherSession = AgentDictation(target: .chatGPT, body: "Harikasın", send: true, session: .new)
        XCTAssertFalse(UnreadSessionRecap.allowsReplySend(anotherSession, isRecap: true, expectedID: "recapped", capturedID: "recapped", capturedAgent: .chatGPT))
    }

    func testUnreadMarkersFailClosedAndIncludeManualUnread() throws {
        let codex = #"{"electron-thread-read-state-v1":{"version":1,"unreadByIdentity":{"account":{"local:key":["a"],"durable:key":["b"]}}}}"#
        XCTAssertEqual(try UnreadSessionRecap.codexUnreadIDs(Data(codex.utf8)), ["a", "b"])
        XCTAssertThrowsError(try UnreadSessionRecap.codexUnreadIDs(Data(#"{"electron-thread-read-state-v1":{"version":1,"unreadByIdentity":{"a":{},"b":{}}}}"#.utf8)))
        XCTAssertEqual(try UnreadSessionRecap.claudeUnreadIDs(#"{"version":0,"state":{"unreadIds":["a"],"explicitUnreadIds":["b"]}}"#), ["a", "b"])
        XCTAssertThrowsError(try UnreadSessionRecap.claudeUnreadIDs("{}"))
    }
    func testCodexOnlyCompletedFinalPair() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hava nasıl?"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Bakıyorum"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Yağmur bekleniyor."}]}}"#,
        ].joined(separator: "\n")
        XCTAssertNil(UnreadSessionRecap.exchange(in: lines, agent: .chatGPT))
        let completed = lines + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        XCTAssertEqual(UnreadSessionRecap.exchange(in: completed, agent: .chatGPT), .init(question: "Hava nasıl?", answer: "Yağmur bekleniyor."))
        XCTAssertNil(UnreadSessionRecap.exchange(in: completed + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"#, agent: .chatGPT))
    }
    func testClaudeSkipsToolsAndSidechains() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Hava nasıl?"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Bakıyorum"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"TOOL"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Yağmur bekleniyor."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"SUBAGENT"}]}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(UnreadSessionRecap.exchange(in: lines, agent: .claudeCode), .init(question: "Hava nasıl?", answer: "Yağmur bekleniyor."))
        XCTAssertNil(UnreadSessionRecap.exchange(in: lines + "\n" + #"{"type":"user","message":{"role":"user","content":"Yarın?"}}"#, agent: .claudeCode))
    }
}
