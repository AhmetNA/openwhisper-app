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

    func testNewSessionAfterAgentName() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da yeni session'a şunu gönder: testleri çalıştır"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır", send: true, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'a yeni bir konuşmada şunu yaz README'yi güncelle gönder"),
                       AgentDictation(target: .claudeCode, body: "README'yi güncelle", send: true, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'da yeni Spotify'a bunu gönder selam naber"),
                       AgentDictation(target: .claudeCode, body: "selam naber", send: true, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da yeni session aç ve şunu yaz merhaba")?.session, .new)
        XCTAssertEqual(AgentCommandParser.parse("Claude'a yeni konuşmaya merhaba de gönder"),
                       AgentDictation(target: .claudeCode, body: "merhaba de", send: true, session: .new))
    }

    func testNewSessionWithoutAgentNameMeansClaude() {
        XCTAssertEqual(AgentCommandParser.parse("Yeni session'a şunu gönder: build'i kontrol et"),
                       AgentDictation(target: .claudeCode, body: "build'i kontrol et", send: true, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("New Session bunu gönder selam"),
                       AgentDictation(target: .claudeCode, body: "selam", send: true, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Yeni konuşmaya bunu gönder selam")?.session, .new)
        XCTAssertNotEqual(AgentCommandParser.parse("Yeni ChatGPT'ye yaz selam")?.session, .new)
    }

    /// Real Whisper output from the 2026-10-15 voice test.
    func testMisheardSessionWords() {
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'da yeni sesion aç."),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Yeni seçeneğine şunu yaz merhaba"),
                       AgentDictation(target: .claudeCode, body: "merhaba", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Sağ seçeneğine şunu gönder. Selam."),
                       AgentDictation(target: .claudeCode, body: "Selam.", send: true, session: .last))
        XCTAssertNil(AgentCommandParser.parse("Sağ taraftaki seçeneğe tıkla"))
    }

    func testLastSession() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da son session'a gönder testleri tekrar çalıştır"),
                       AgentDictation(target: .claudeCode, body: "testleri tekrar çalıştır", send: true, session: .last))
        XCTAssertEqual(AgentCommandParser.parse("Son sesine gönder selam naber"),
                       AgentDictation(target: .claudeCode, body: "selam naber", send: true, session: .last))
        XCTAssertEqual(AgentCommandParser.parse("Claude'a bir önceki session'da şunu yaz devam et gönder")?.session, .last)
    }

    func testYeniWithoutSessionWordStaysInBody() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'a yeni bir özellik ekle gönder"),
                       AgentDictation(target: .claudeCode, body: "yeni bir özellik ekle", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'a yaz yeni session'a geçelim gönder"),
                       AgentDictation(target: .claudeCode, body: "yeni session'a geçelim", send: true))
        XCTAssertNil(AgentCommandParser.parse("Yeni session açtım bugün"))
    }

    func testSessionWordWithOtherEndingsStaysInBody() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'a yeni session butonunu kontrol et gönder"),
                       AgentDictation(target: .claudeCode, body: "yeni session butonunu kontrol et", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Claude'a son konuşmayı özetle gönder"),
                       AgentDictation(target: .claudeCode, body: "son konuşmayı özetle", send: true))
        XCTAssertEqual(AgentCommandParser.parse("Claude'a yeni sohbeti kaydet gönder"),
                       AgentDictation(target: .claudeCode, body: "yeni sohbeti kaydet", send: true))
    }

    func testOpenNewSessionAlone() {
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da yeni session aç"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Yeni bir konuşma açar mısın?")?.session, .new)
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'da yeni Spotify aç")?.session, .new)
        XCTAssertNil(AgentCommandParser.parse("Yeni Spotify aç"))
    }
}

final class AgentSwitchParserTests: XCTestCase {
    func testSwitchThenSend() {
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Claude Code'a geç ve şunu yolla: testleri çalıştır ve hataları düzelt"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır ve hataları düzelt", send: true))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Cloud koda geç, şunu yaz merhaba"),
                       AgentDictation(target: .claudeCode, body: "merhaba", send: false))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("ChatGPT'ye geç ve şunu sor: bugün hava nasıl"),
                       AgentDictation(target: .chatGPT, body: "bugün hava nasıl", send: false))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Hey Jarvis, Claude'a geç ve README'yi güncelle, gönder"),
                       AgentDictation(target: .claudeCode, body: "README'yi güncelle", send: true))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Claude'a geç ve merhaba yaz"),
                       AgentDictation(target: .claudeCode, body: "merhaba", send: false))
    }

    func testSwitchThenNewSession() {
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Claude Code'a geç ve yeni session başlat"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Cloud koda geç ve yeni sesine başlat"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parseAfterSwitch("Claude'a geç, yeni session'a şunu yaz merhaba")?.session, .new)
    }

    func testNotAnAgentFollowUp() {
        XCTAssertNil(AgentCommandParser.parseAfterSwitch("Claude Code'a geç"))
        XCTAssertNil(AgentCommandParser.parseAfterSwitch("Safari'ye geç ve şunu yolla merhaba"))
        XCTAssertNil(AgentCommandParser.parseAfterSwitch("Claude'a geç ve Wi-Fi'yi kapat"))
        XCTAssertNil(AgentCommandParser.parseAfterSwitch("Claude'a geçtim ve şunu yolla merhaba"))
    }
}
