import XCTest
@testable import OpenWhisper

/// "Biten sohbete geç" and "Codex'te son sohbeti özetle": recognising the ask, telling a
/// finished chat from a running one. No files or apps.
final class AgentFinishedChatTests: XCTestCase {

    func testFinishedChatRequests() {
        let cases: [(String, AgentApp?)] = [
            ("Biten sohbete geç", nil),
            ("biten session'a geç", nil),
            ("Yanıt gelene geç", nil),
            ("Cevabı gelen sohbete geç.", nil),
            ("İşi biten sohbete geçer misin", nil),
            ("Bitene geç", nil),
            ("Bitmiş çete geç", nil),
            ("Hey Jarvis, biten sohbete geç", nil),
            ("Claude'da biten session'a geç", .claudeCode),
            ("Codex'te cevabı gelen sohbeti aç", .codex),
            ("ChatGPT'de yanıtı gelen sohbete geç", .chatGPT),
        ]
        for (text, target) in cases {
            XCTAssertEqual(AgentCommandParser.finishedChatRequest(text), FinishedChatRequest(target: target), text)
        }
    }

    func testNotFinishedChatRequests() {
        for text in [
            "Biten sohbete geçmeden önce testleri çalıştır",
            "Claude'a şunu yaz: biten sohbete geç butonu ekle",
            "Toplantı bitince sohbete geç",
            "Son sohbete geç",
            "Biten şarkıyı tekrar aç",
        ] {
            XCTAssertNil(AgentCommandParser.finishedChatRequest(text), text)
        }
    }

    func testCloudNavigationLeavesFinishedChatAlone() {
        XCTAssertFalse(CloudSessionNavigation.isRequest("Biten sohbete geç"))
        XCTAssertTrue(CloudSessionNavigation.isRequest("Takvim sohbetine geç"))
    }

    @MainActor
    func testRoutes() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .notEditable,
                                      hasTargetApp: false, targetBundleID: nil)
        guard case .finishedAgentChat(nil) = VoiceRouter.route("Biten sohbete geç", facts: facts) else {
            return XCTFail("not routed to the finished chat")
        }
        guard case .agentSessionRecap(.codex) = VoiceRouter.route("Codex'te son sohbeti özetle", facts: facts) else {
            return XCTFail("not routed to the Codex recap")
        }
    }

    func testCodexSummaryRequests() {
        for text in ["Codex'te son sohbeti özetle", "ChatGPT'de son cevabı özetler misin", "Kodekste ne yaptık", "Codex'te nerede kalmıştık"] {
            XCTAssertEqual(AgentCommandParser.sessionSummaryTarget(text), .codex, text)
        }
        XCTAssertEqual(AgentCommandParser.sessionSummaryTarget("Son session'ı özetle"), .claudeCode)
        XCTAssertNil(AgentCommandParser.sessionSummaryTarget("Codex'e özet gönder"))
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testClaudeFinishedOnlyAfterTheTurnEnds() {
        let base: [String: Any] = ["sessionId": "local_1", "title": "Takvim", "completedTurns": 2,
                                   "latestUserFrameAt": 1_000_000.0]
        var finished = base
        finished["lastTurnEdgeAt"] = 1_090_000.0
        XCTAssertEqual(AgentFinishedChat.claudeChat(fromJSON: json(finished))?.finishedAt,
                       Date(timeIntervalSince1970: 1090))
        // The turn's start edge lands a few ms around the message.
        var running = base
        running["lastTurnEdgeAt"] = 999_981.0
        XCTAssertNil(AgentFinishedChat.claudeChat(fromJSON: json(running)))
        running["lastTurnEdgeAt"] = 1_000_019.0
        XCTAssertNil(AgentFinishedChat.claudeChat(fromJSON: json(running)))
        var archived = finished
        archived["isArchived"] = true
        XCTAssertNil(AgentFinishedChat.claudeChat(fromJSON: json(archived)))
    }

    func testCodexFinishedOnlyWhenTheLastTaskCompleted() {
        let done = """
        {"timestamp":"2026-10-27T18:10:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-27T18:15:33.925Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Bitti"}}
        """
        XCTAssertNotNil(AgentFinishedChat.codexFinishedAt(inRollout: done))
        let running = done + "\n" + #"{"timestamp":"2026-10-27T18:20:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
        XCTAssertNil(AgentFinishedChat.codexFinishedAt(inRollout: running))
    }

    func testNewestSkipsTheChatOnScreen() {
        let older = AgentFinishedChat.Chat(agent: .claudeCode, id: "a", title: "A", finishedAt: Date(timeIntervalSince1970: 1))
        let newer = AgentFinishedChat.Chat(agent: .codex, id: "b", title: "B", finishedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(AgentFinishedChat.newest([older, newer], excluding: nil), newer)
        XCTAssertEqual(AgentFinishedChat.newest([older, newer], excluding: "b"), older)
        XCTAssertNil(AgentFinishedChat.newest([older], excluding: "a"))
    }
}
