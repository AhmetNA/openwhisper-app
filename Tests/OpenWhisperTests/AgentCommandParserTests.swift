import XCTest
@testable import OpenWhisper

/// Pure parsing tests — no app activation or keystrokes.
final class AgentCommandParserTests: XCTestCase {

    func testClaudeCodeTargetWithSend() {
        let result = AgentCommandParser.parse("Claude Code'a şunu yaz: testleri çalıştır ve hataları düzelt. Gönder.")
        XCTAssertEqual(result, AgentDictation(target: .claudeCode, body: "testleri çalıştır ve hataları düzelt", send: true))
    }

    func testMisheardCloudCode() {
        let result = AgentCommandParser.parse("Cloud Code'a yaz README dosyasını güncelle gönder")
        XCTAssertEqual(result?.target, .claudeCode)
        XCTAssertEqual(result?.body, "README dosyasını güncelle")
        XCTAssertEqual(result?.send, true)
    }

    func testMergedCloudcoWithLocativeSuffix() {
        XCTAssertEqual(AgentCommandParser.parse("Cloudco'da şunu yaz bu bir test"),
                       AgentDictation(target: .claudeCode, body: "bu bir test", send: false))
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da şunu yaz bu bir test gönder")?.body, "bu bir test")
        XCTAssertEqual(AgentCommandParser.parse("Codex'te şunu yaz selam")?.target, .codex)
        XCTAssertEqual(AgentCommandParser.parse("Klod koda yaz selam")?.body, "selam")
    }

    func testTypographicApostropheAndClaudeOnly() {
        let result = AgentCommandParser.parse("Claude’a şöyle yaz, merhaba")
        XCTAssertEqual(result, AgentDictation(target: .claudeCode, body: "merhaba", send: false))
    }

    func testCodexTarget() {
        let result = AgentCommandParser.parse("Codex'e şunu yaz: login sayfasını düzelt ve gönder")
        XCTAssertEqual(result, AgentDictation(target: .codex, body: "login sayfasını düzelt", send: true))
    }

    func testMisheardKodeks() {
        let result = AgentCommandParser.parse("Kodekse yaz build hatasına bak sonra gönder.")
        XCTAssertEqual(result, AgentDictation(target: .codex, body: "build hatasına bak", send: true))
    }

    func testTrailingSendWithoutTarget() {
        let result = AgentCommandParser.parse("Bu fonksiyonu refactor et, gönder!")
        XCTAssertEqual(result, AgentDictation(target: nil, body: "Bu fonksiyonu refactor et", send: true))
    }

    func testMidSentenceGonderIsKept() {
        XCTAssertNil(AgentCommandParser.parse("Maili gönder butonunu sağa taşı"))
    }

    func testPlainDictationIsNotAgent() {
        XCTAssertNil(AgentCommandParser.parse("Yarın toplantı saat üçte"))
        XCTAssertNil(AgentCommandParser.parse("Claude Code'a geçtim bugün"))
    }

    func testQuotedBodyWithSendInsideQuotes() {
        let result = AgentCommandParser.parse(#"Cloud Code'a şunu yaz: "Proje Voice2Text Selam naber bu bir test mesajı gönder""#)
        XCTAssertEqual(result, AgentDictation(target: .claudeCode, body: "Proje Voice2Text Selam naber bu bir test mesajı", send: true))
    }

    func testSendVerbInPrefixSends() {
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'a gönder selam naber"),
                       AgentDictation(target: .claudeCode, body: "selam naber", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Codex'e şunu yolla: build'e bak"),
                       AgentDictation(target: .codex, body: "build'e bak", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'a şunu gönder: testleri çalıştır gönder"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır", send: true))
    }

    func testMisheardKilikKod() {
        XCTAssertEqual(AgentCommandParser.parse("Kılık koda gönder selam naber"),
                       AgentDictation(target: .claudeCode, body: "selam naber", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Kılık Code'a şunu yaz: testleri çalıştır"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır", send: false))
    }

    func testAnySendFormAtTheEnd() {
        for ending in ["gönder", "gönderildi", "gönderme", "gönderir misin", "yolla", "yolla bunu", "ve yolla.", "gönder hemen", "Gönder!"] {
            let result = AgentCommandParser.parse("Codex'e yaz selam naber \(ending)")
            XCTAssertEqual(result?.body, "selam naber", ending)
            XCTAssertEqual(result?.send, true, ending)
        }
    }

    func testOnlyCommandWordsGiveEmptyBody() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'a yaz gönder"),
                       AgentDictation(target: .claudeCode, body: "", send: true))
    }
}
