import XCTest
@testable import OpenWhisper

/// "Claude'da son session'ı özetle": recognising the ask, picking the session's text. No files or models.
final class ClaudeSessionRecapTests: XCTestCase {

    func testSummaryRequests() {
        for text in [
            "Claude'da son session'ı özetle",
            "Cloud Code son sesinden özet",
            "Claude Code'da son session'da ne yaptık?",
            "Son session'ı özetler misin",
            "Claude'da nerede kalmıştık",
            "Klod koda son oturumu özetle.",
            "Claude'da en son ne yaptık",
            "Son sesinde neler yaptığını özetle",
            "Claude'daki son sohbetin özetini ver",
        ] {
            XCTAssertTrue(AgentCommandParser.isSessionSummaryRequest(text), text)
        }
    }

    func testNotSummaryRequests() {
        for text in [
            "Ne yaptık bugün",
            "Bu makaleyi özetle",
            "Claude'a şunu yaz: bu dosyayı özetle",
            "Son session'a yaz testleri çalıştır",
            "Claude'a özet gönder",
            "Son şarkıyı özetle",
        ] {
            XCTAssertFalse(AgentCommandParser.isSessionSummaryRequest(text), text)
        }
    }

    @MainActor
    func testRoutesToRecapOnlyInVoiceSessions() {
        var facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .notEditable,
                                      hasTargetApp: false, targetBundleID: nil)
        guard case .claudeSessionRecap = VoiceRouter.route("Claude'da son session'ı özetle", facts: facts) else {
            return XCTFail("not routed to the recap")
        }
        facts.isVoiceCommand = false
        if case .claudeSessionRecap = VoiceRouter.route("Claude'da son session'ı özetle", facts: facts) {
            XCTFail("dictation must not run the recap")
        }
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private let base: [String: Any] = [
        "sessionId": "local_1", "cliSessionId": "abc", "title": "Takvim", "completedTurns": 3,
        "lastActivityAt": 1_792_696_294_655.0, "lastAssistantUuid": "u2",
    ]

    func testStoredRecapUsedWhenItSummarizesTheLastAnswer() {
        var fresh = base
        fresh["postTurnSummary"] = ["summarizes_uuid": "u2", "status_detail": "718 test geçti"]
        fresh["turnWrapUp"] = ["description": "Takvimi artık SetFit tanıyor."]
        let session = ClaudeSessionRecap.session(fromJSON: json(fresh))
        XCTAssertEqual(session?.id, "local_1")
        XCTAssertEqual(session?.transcriptID, "abc")
        XCTAssertEqual(session?.storedRecap, "Takvimi artık SetFit tanıyor.")

        var stale = fresh
        stale["postTurnSummary"] = ["summarizes_uuid": "u1", "status_detail": "eski"]
        XCTAssertNil(ClaudeSessionRecap.session(fromJSON: json(stale))?.storedRecap)

        var detailOnly = fresh
        detailOnly["turnWrapUp"] = [String: Any]()
        XCTAssertEqual(ClaudeSessionRecap.session(fromJSON: json(detailOnly))?.storedRecap, "718 test geçti")
    }

    func testArchivedAndUnansweredSessionsSkipped() {
        var archived = base
        archived["isArchived"] = true
        XCTAssertNil(ClaudeSessionRecap.session(fromJSON: json(archived)))
        var empty = base
        empty["completedTurns"] = 0
        XCTAssertNil(ClaudeSessionRecap.session(fromJSON: json(empty)))
    }

    func testLastAssistantText() {
        let lines = [
            #"{"type":"user","message":{"content":"selam"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"İlk cevap."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Son cevap burada."}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]
        XCTAssertEqual(ClaudeSessionRecap.lastAssistantText(inTranscript: lines.joined(separator: "\n")), "Son cevap burada.")
    }

    func testFallbackSummary() {
        XCTAssertEqual(ClaudeSessionRecap.fallbackSummary(storedRecap: "Hazır **oldu**.", lastMessage: "x"), "Hazır oldu.")
        XCTAssertEqual(ClaudeSessionRecap.fallbackSummary(
            storedRecap: nil, lastMessage: "Takvim düzeldi. Testler geçti. Commit atıldı.\n\n**Detay:** uzun"),
            "Takvim düzeldi. Testler geçti.")
        XCTAssertNil(ClaudeSessionRecap.fallbackSummary(storedRecap: nil, lastMessage: nil))
    }

    func testModelAnswerCutToTwoSentences() {
        XCTAssertEqual(ClaudeSessionRecap.twoSentences("Bir bitti. İki kaldı. Üç de"), "Bir bitti. İki kaldı.")
        XCTAssertEqual(ClaudeSessionRecap.twoSentences("Takvim düzeldi"), "Takvim düzeldi")
    }
}
