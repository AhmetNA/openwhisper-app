import XCTest
@testable import OpenWhisper

/// The session facts `RouteCorpusTests` keeps fixed: focus, a pending deletion, no app in front.
@MainActor
final class VoiceRouterTests: XCTestCase {
    private func facts(voice: Bool = true, focus: TextFocusStatus = .unknown, hasTargetApp: Bool = true,
                       targetBundleID: String? = nil, pendingDeletion: Bool = false,
                       overPlayback: Bool = false) -> VoiceRouter.Facts {
        VoiceRouter.Facts(isVoiceCommand: voice, acceptsCommands: true, focus: focus,
                          hasTargetApp: hasTargetApp, targetBundleID: targetBundleID,
                          pendingDeletion: pendingDeletion, commandAmongPlayback: overPlayback)
    }

    func testVoiceFarewellsLockButExplanationsAndDictationDoNot() {
        for text in ["Hey Jarvis, görüşürüz, kendine iyi bak.", "Jarvis bay bay",
                     "Teşekkürler. Görüşürüz. Kendine iyi bakın.", "Görüşmek üzere",
                     "Bilgisayarı kapatalım", "Bilgisayarı kilitleyelim"] {
            guard case .command(.system(.lockScreen)) = VoiceRouter.route(text, facts: facts(focus: .editable)) else {
                return XCTFail("Expected lock: \(text)")
            }
        }
        for text in ["Görüşürüz, kendine iyi bak gibi kelimelerin uykuya geçirmesini sağlayalım",
                     "Yeni bir ayar yapalım. Mesela hey Jarvis bay bay. Bunlar bilgisayarı kilitlemeli.",
                     "Bilgisayarı kilitleyelim dediğimde ne oluyor?", "Görüşürüz deme",
                     "Buraya yaz görüşürüz kendine iyi bak"] {
            if case .command(.system(.lockScreen)) = VoiceRouter.route(text, facts: facts(overPlayback: true)) {
                XCTFail("Not an immediate lock request: \(text)")
            }
        }
        if case .command(.system(.lockScreen)) = VoiceRouter.route("Görüşürüz kendine iyi bak", facts: facts(voice: false, focus: .editable)) {
            XCTFail("Keyboard dictation must stay text")
        }
    }

    func testOpenChatGPTAndVolumeChainFromSafari() {
        for focus: TextFocusStatus in [.notEditable, .editable, .unknown] {
            guard case .commands(let steps) = VoiceRouter.route(
                "ChatGPT 'yi aç ve sesi kız.",
                facts: facts(focus: focus, targetBundleID: "com.apple.Safari")) else {
                return XCTFail("Both commands must route from Safari")
            }
            XCTAssertEqual(steps.map(\.command), [.system(.switchToAgent(.chatGPT)), .spotify("sesi kıs")])
            XCTAssertEqual(SpotifyManager.explicitIntent(in: "sesi kıs"), .adjustVolume(-20))
        }
    }

    func testRecentYouTubeFailuresRouteAsVoiceCommands() {
        for text in ["Yutu vat-salam", "Youtube'a bakan", "Youtube'da ne izleyebilirim?",
                     "Hey Jarvis, yutup açsana", "You tube'a bakalım"] {
            guard case .command(.system(.browser(.youtubeHome))) = VoiceRouter.route(
                text, facts: facts(focus: .editable, targetBundleID: "com.openai.codex")) else {
                return XCTFail("YouTube request fell through: \(text)")
            }
        }
        for text in ["Yutu vat-salam", "Youtube'a bakan", "YouTube'a bakan insanları gördüm"] {
            if case .command(.system(.browser(.youtubeHome))) = VoiceRouter.route(text, facts: facts(voice: false, focus: .editable)) {
                XCTFail("Literal dictation must not be repaired: \(text)")
            }
        }
        guard case .typed = VoiceRouter.route("buraya yaz Yutu vat-salam", facts: facts(focus: .editable)) else {
            return XCTFail("Explicit dictation wins")
        }
        guard case .deletionConfirmation = VoiceRouter.route("Yutu vat-salam", facts: facts(pendingDeletion: true)) else {
            return XCTFail("Pending confirmation wins")
        }
    }

    func testYouTubeListingDoesNotFallThroughToCloudChat() {
        for text in ["YouTube'da neyler var?", "YouTube'da neler var?",
                     "Youtube'da güncel videolar neler var?", "YouTube'da ne izleyebilirim?"] {
            for focus: TextFocusStatus in [.unknown, .editable] {
                guard case .command(.system(.browser(.youtubeHome))) = VoiceRouter.route(
                    text, facts: facts(focus: focus, targetBundleID: "com.openai.codex")) else {
                    return XCTFail("YouTube listing fell through: \(text)")
                }
            }
        }
        guard case .typed = VoiceRouter.route(
            "buraya yaz YouTube'da neyler var?", facts: facts(focus: .editable)) else {
            return XCTFail("Explicit dictation must remain dictation")
        }
    }

    func testOpenAgentCommandWinsOverDictation() {
        for voice in [true, false] {
            for (text, target) in [("Kodeksi aç", AgentApp.codex), ("ChatGPT'yi aç", .chatGPT),
                                   ("cloud 'u aç", .claudeCode), ("cloud kodu aç", .claudeCode),
                                   ("Cloud’u hemen aç", .claudeCode), ("Klaut kudu aç?", .claudeCode),
                                   ("Klanat kodu açar mısın?", .claudeCode),
                                   ("Kılaat kodu açar mısın?", .claudeCode),
                                   ("Şu anda Cloud Code 'u açar mısın?", .claudeCode)] {
                guard case .command(.system(.switchToAgent(let agent))) = VoiceRouter.route(
                    text, facts: facts(voice: voice, focus: .editable)) else {
                    return XCTFail("\(text) must open the app even in a text field")
                }
                XCTAssertEqual(agent, target)
            }
        }
        guard case .typed("Kodeksi aç") = VoiceRouter.route("buraya yaz Kodeksi aç", facts: facts(focus: .editable)) else {
            return XCTFail("explicit dictation must still type the phrase")
        }
    }

    func testGreetingIsDictationInATextField() {
        guard case .greeting = VoiceRouter.route("Günaydın", facts: facts(focus: .notEditable)) else {
            return XCTFail("a greeting with no text field is answered")
        }
        if case .greeting = VoiceRouter.route("Günaydın", facts: facts(focus: .editable)) {
            XCTFail("a greeting in a text field is typed")
        }
    }

    func testJarvisRoutesNeedAVoiceSession() {
        if case .greeting = VoiceRouter.route("Günaydın", facts: facts(voice: false, focus: .notEditable)) {
            XCTFail("the dictation keys never greet")
        }
    }

    func testPendingDeletionTakesTheAnswerBeforeCommands() {
        guard case .deletionConfirmation = VoiceRouter.route("evet", facts: facts(pendingDeletion: true)) else {
            return XCTFail("a pending deletion gets the answer")
        }
        if case .deletionConfirmation = VoiceRouter.route("evet", facts: facts()) {
            XCTFail("no deletion waits")
        }
    }

    func testTestModeAnswersOnlyWhileOn() {
        guard case .voiceTest(.start) = VoiceRouter.route("Test modunu başlat", facts: facts()) else {
            return XCTFail("test mode starts by voice")
        }
        var on = facts()
        on.voiceTestActive = true
        guard case .voiceTest(.passed) = VoiceRouter.route("Geçti", facts: on) else {
            return XCTFail("while testing, \"geçti\" is the answer")
        }
        if case .voiceTest = VoiceRouter.route("Geçti", facts: facts()) {
            XCTFail("outside test mode \"geçti\" is ordinary talk")
        }
        guard case .command = VoiceRouter.route("Wi-Fi'yi kapat", facts: on) else {
            return XCTFail("commands still run while testing")
        }
    }

    func testExistingDraftSendRequests() {
        for text in ["gönder", "Hey Jarvis, gönder", "gönderebilir misin bunu?",
                     "gönderir misin bunu", "mesajı ilet", "mesajı yolla",
                     "bunu gönder", "lütfen bu mesajı gönder", "yollar mısın bunu"] {
            guard case .sendExistingMessage = VoiceRouter.route(text, facts: facts(focus: .editable)) else {
                XCTFail("Must submit existing draft: \(text)")
                continue
            }
            guard case .agentWithoutForeground = VoiceRouter.route(text, facts: facts(hasTargetApp: false)) else {
                return XCTFail("No app must not send")
            }
            if case .sendExistingMessage = VoiceRouter.route(text, facts: facts(voice: false)) {
                XCTFail("Send-only action requires a Jarvis session")
            }
        }
        for text in ["gönderme", "mesajı yollama", "mesajı iletme", "gönderdim",
                     "bana dosyayı gönderir misin", "buraya yaz mesajı yolla", "merhaba gönder"] {
            XCTAssertFalse(AgentCommandParser.isExistingMessageSend(text), text)
        }
        var pending = facts()
        pending.pendingWhatsAppSend = true
        guard case .whatsAppConfirmation = VoiceRouter.route("gönder", facts: pending) else {
            return XCTFail("Pending WhatsApp draft retains its confirmation flow")
        }
    }

    func testSendWithNoAppInFront() {
        guard case .agentWithoutForeground = VoiceRouter.route("bunu düzelt gönder", facts: facts(hasTargetApp: false)) else {
            return XCTFail("a Jarvis send with nothing in front is refused")
        }
    }

    func testProjectAndCodexSessionCommandsGoToTheAgent() {
        for text in ["Bitirme projesine geç", "Codex'te yeni session aç", "Voice2TextLocal projesinde Claude'a şunu yaz merhaba"] {
            guard case .agent = VoiceRouter.route(text, facts: facts(hasTargetApp: false)) else {
                return XCTFail("'\(text)' goes to the agent")
            }
        }
    }

    func testKeySendOnlyIntoAnEditableAgentApp() {
        let agentApp = AgentApp.sendCapableBundleIdentifiers.sorted().first
        guard case .agent = VoiceRouter.route("bunu düzelt gönder", facts: facts(voice: false, focus: .editable, targetBundleID: agentApp)) else {
            return XCTFail("Fn into an agent app sends")
        }
        guard case .typed = VoiceRouter.route("bunu düzelt gönder", facts: facts(voice: false, focus: .editable, targetBundleID: "com.tinyspeck.slackmacgap")) else {
            return XCTFail("Fn into Slack types without Return")
        }
    }

    /// 17 Oct 2026: what Whisper heard of the user's command between a video's sentences.
    func testCommandBetweenThePlaybacksSentences() {
        let heard = "Bu da bir çeşit pratik falan görevli oldu. Videoyu durdur. Çok yavaş."
        guard case .command(.system(.video)) = VoiceRouter.route(heard, facts: facts(focus: .notEditable, overPlayback: true)) else {
            return XCTFail("over media any sentence may be the command")
        }
        if case .command = VoiceRouter.route(heard, facts: facts(focus: .notEditable)) {
            XCTFail("elsewhere only the first sentence counts")
        }
        guard case .command(.system(.time)) = VoiceRouter.route(
            "Saat kaç? Bu hikaye bir turist ile başlıyor. 1867'de özel bir hava.", facts: facts(focus: .notEditable, overPlayback: true)) else {
            return XCTFail("the command first, then the video")
        }
    }
}
