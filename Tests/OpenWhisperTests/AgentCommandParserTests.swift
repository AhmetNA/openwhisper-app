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

    func testNewChatInCodexAndClaude() {
        XCTAssertEqual(AgentCommandParser.parse("Claude'da yeni sohbet aç"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Codex'te yeni session aç"),
                       AgentDictation(target: .codex, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Kodekste yeni sohbet aç")?.target, .codex)
        XCTAssertEqual(AgentCommandParser.parse("Klod'da yeni sohbet açar mısın")?.session, .new)
        // Real Whisper output from the 2026-10-22 voice test.
        XCTAssertEqual(AgentCommandParser.parse("CloudCode'da şu an yeni bir sesion aç."),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Kodekste hemen yeni bir chat aç lütfen")?.target, .codex)
        XCTAssertEqual(AgentCommandParser.parse("Şimdi yeni bir chat aç")?.session, .new)
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'da yeni çat aç."),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new))
        XCTAssertEqual(AgentCommandParser.parse("Codex'te yeni çete aç")?.target, .codex)
        XCTAssertEqual(AgentCommandParser.parse("Codex'te yeni session'a şunu yaz merhaba"),
                       AgentDictation(target: .codex, body: "merhaba", send: false, session: .new))
    }

    func testProjectWithoutAppAssumesClaude() {
        XCTAssertEqual(AgentCommandParser.parse("Bitirme projesine yaz: raporu güncelle"),
                       AgentDictation(target: .claudeCode, body: "raporu güncelle", send: false, project: "Bitirme", targetAssumed: true))
        XCTAssertEqual(AgentCommandParser.parse("Voice2TextLocal projesine şunu gönder testleri çalıştır"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır", send: true, project: "Voice2TextLocal", targetAssumed: true))
        XCTAssertEqual(AgentCommandParser.parse("Voice to text local projesine yaz build'i kontrol et gönder"),
                       AgentDictation(target: .claudeCode, body: "build'i kontrol et", send: true, project: "Voice to text local", targetAssumed: true))
    }

    func testProjectThenNamedApp() {
        XCTAssertEqual(AgentCommandParser.parse("Voice2TextLocal projesinde Claude'a şunu yaz: README'yi güncelle"),
                       AgentDictation(target: .claudeCode, body: "README'yi güncelle", send: false, project: "Voice2TextLocal"))
        XCTAssertEqual(AgentCommandParser.parse("Bitirme projesinde Cloud Code'a şunu gönder selam"),
                       AgentDictation(target: .claudeCode, body: "selam", send: true, project: "Bitirme"))
        XCTAssertEqual(AgentCommandParser.parse("Bitirme projesinde kodekse yaz merhaba"),
                       AgentDictation(target: .codex, body: "merhaba", send: false, project: "Bitirme"))
    }

    func testAppThenProject() {
        XCTAssertEqual(AgentCommandParser.parse("Codex'te Bitirme projesine yaz merhaba"),
                       AgentDictation(target: .codex, body: "merhaba", send: false, project: "Bitirme"))
        XCTAssertEqual(AgentCommandParser.parse("Klod'da OpenWhisper projesine şunu gönder: testleri çalıştır"),
                       AgentDictation(target: .claudeCode, body: "testleri çalıştır", send: true, project: "OpenWhisper"))
    }

    func testNewSessionInProject() {
        XCTAssertEqual(AgentCommandParser.parse("Bitirme projesinde yeni session aç"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new, project: "Bitirme", targetAssumed: true))
        XCTAssertEqual(AgentCommandParser.parse("Codex'te Bitirme projesinde yeni sohbet aç"),
                       AgentDictation(target: .codex, body: "", send: false, session: .new, project: "Bitirme"))
        // Voice test 2026-10-24: went to cloud chat navigation and opened an unrelated chat.
        XCTAssertEqual(AgentCommandParser.parse("bitirme projesinde yeni çet aç"),
                       AgentDictation(target: .claudeCode, body: "", send: false, session: .new, project: "bitirme", targetAssumed: true))
        XCTAssertEqual(AgentCommandParser.parse("Cloud Code'da Voice2TextLocal projesinde yeni session'a şunu gönder merhaba"),
                       AgentDictation(target: .claudeCode, body: "merhaba", send: true, session: .new, project: "Voice2TextLocal"))
    }

    func testSwitchToProject() {
        XCTAssertEqual(AgentCommandParser.parse("Bitirme projesine geç"),
                       AgentDictation(target: .claudeCode, body: "", send: false, project: "Bitirme", targetAssumed: true))
        XCTAssertEqual(AgentCommandParser.parse("Codex'te Bitirme projesini aç"),
                       AgentDictation(target: .codex, body: "", send: false, project: "Bitirme"))
    }

    func testProjectWordInsideDictationIsNoCommand() {
        XCTAssertNil(AgentCommandParser.parse("Bitirme projesine bugün çok çalıştım"))
        XCTAssertNil(AgentCommandParser.parse("Bu projeye yaz bunu"))
        XCTAssertNil(AgentCommandParser.parse("Yeni projede şunu yaz merhaba"))
        // A "projesine" inside the message stays in the message.
        XCTAssertEqual(AgentCommandParser.parse("Claude'a şunu yaz Bitirme projesine bak gönder"),
                       AgentDictation(target: .claudeCode, body: "Bitirme projesine bak", send: true))
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

final class AgentProjectMatcherTests: XCTestCase {
    private let projects = [
        AgentProject(name: "Voice2TextLocal", folder: "/u/Github/Voice2TextLocal"),
        AgentProject(name: "Bitirme", folder: "/u/Github/Bitirme"),
        AgentProject(name: "OpenWhisper", folder: "/u/Kişisel Projeler/Voice2TextLocal"),
        AgentProject(name: "Yeni Nesil", folder: "/u/YeniNesilWeb"),
        AgentProject(name: "4x1", folder: "/u/Okul/4x1"),
    ]

    private func name(_ spoken: String) -> String? {
        if case .found(let project) = AgentProjectMatcher.match(spoken, in: projects) { return project.name }
        return nil
    }

    func testSpokenFormsFindTheProject() {
        XCTAssertEqual(name("Bitirme"), "Bitirme")
        XCTAssertEqual(name("bitirme"), "Bitirme")
        XCTAssertEqual(name("Open Whisper"), "OpenWhisper")
        XCTAssertEqual(name("Open Visper"), "OpenWhisper")
        XCTAssertEqual(name("yeni nesil web"), "Yeni Nesil")
        XCTAssertEqual(name("dört x bir"), "4x1")
    }

    func testSameNameInTwoFoldersIsAmbiguousOnlyWhenNamesDiffer() {
        // "Voice2TextLocal" is the folder of both the Voice2TextLocal and OpenWhisper entries.
        guard case .ambiguous(let names) = AgentProjectMatcher.match("voice to text local", in: projects) else { return XCTFail() }
        XCTAssertEqual(Set(names), ["Voice2TextLocal", "OpenWhisper"])
        let moved = [
            AgentProject(name: "Bitirme", folder: "/old/Bitirme",
                         latestSession: AgentProjectSession(id: "a", title: "eski", lastActivity: Date(timeIntervalSince1970: 1))),
            AgentProject(name: "Bitirme", folder: "/new/Bitirme",
                         latestSession: AgentProjectSession(id: "b", title: "yeni", lastActivity: Date(timeIntervalSince1970: 2))),
        ]
        guard case .found(let project) = AgentProjectMatcher.match("bitirme", in: moved) else { return XCTFail() }
        XCTAssertEqual(project.folder, "/new/Bitirme")
    }

    func testUnknownProjectIsNotGuessed() {
        XCTAssertEqual(AgentProjectMatcher.match("Spotify", in: projects), .none)
        XCTAssertEqual(AgentProjectMatcher.match("Roomly", in: projects), .none)
    }
}
