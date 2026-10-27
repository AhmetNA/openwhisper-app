import XCTest
@testable import OpenWhisper

/// The session facts `RouteCorpusTests` keeps fixed: focus, a pending deletion, no app in front.
@MainActor
final class VoiceRouterTests: XCTestCase {
    func testExplicitPlaybackControlsBypassModelRouting() {
        for text in ["Şarkıyı durdur", "Spotify'da devam et", "Sonraki şarkıya geç"] {
            guard case .command(.spotify) = VoiceRouter.route(text, facts: facts()) else {
                XCTFail("Expected local Spotify route: \(text)"); continue
            }
        }
        guard case .typed = VoiceRouter.route("Buraya yaz şarkıyı durdur", facts: facts()) else {
            return XCTFail("Explicit dictation must retain precedence")
        }
        guard case .deletionConfirmation = VoiceRouter.route("Şarkıyı durdur", facts: facts(pendingDeletion: true)) else {
            return XCTFail("Pending confirmation must retain precedence")
        }
        for text in ["Şarkıyı durdurma", "Şarkıyı durdur demedim", "Tarkan'ın Şımarık şarkısını çal"] {
            if case .command(.spotify) = VoiceRouter.route(text, facts: facts()) {
                XCTFail("Must retain existing interpretation: \(text)")
            }
        }
    }
    private func facts(voice: Bool = true, focus: TextFocusStatus = .unknown, hasTargetApp: Bool = true,
                       targetBundleID: String? = nil, pendingDeletion: Bool = false,
                       overPlayback: Bool = false, lastDictation: String? = nil) -> VoiceRouter.Facts {
        VoiceRouter.Facts(isVoiceCommand: voice, acceptsCommands: true, focus: focus,
                          hasTargetApp: hasTargetApp, targetBundleID: targetBundleID,
                          pendingDeletion: pendingDeletion, commandAmongPlayback: overPlayback,
                          lastDictation: lastDictation)
    }

    func testPendingScreenPressTakesTheAnswer() {
        var pending = facts(focus: .notEditable)
        pending.pendingScreenPress = true
        guard case .screenPressConfirmation = VoiceRouter.route("evet", facts: pending) else {
            return XCTFail("a pending press gets the answer")
        }
    }

    func testDictationEditsActOnTheLastDictation() {
        let typing = facts(voice: false, focus: .editable, lastDictation: "Ahmed geldi")
        guard case .dictationEdit(.deleteAll) = VoiceRouter.route("Sil.", facts: typing) else {
            return XCTFail("'sil' after a dictation deletes it")
        }
        guard case .dictationEdit(.replace(old: "Ahmed", new: "Ahmet")) = VoiceRouter.route("Ahmed'i Ahmet yap", facts: typing) else {
            return XCTFail("the misheard name is replaced")
        }
        guard case .dictationEdit(.pressReturn) = VoiceRouter.route("Enter'a bas", facts: facts(voice: false, focus: .editable)) else {
            return XCTFail("Enter needs no dictation before it")
        }
        guard case .typed = VoiceRouter.route("Buraya yaz son kelimeyi sil", facts: typing) else {
            return XCTFail("explicit dictation keeps precedence")
        }
        for text in ["sil", "Ahmed'i Ahmet yap"] {
            if case .dictationEdit = VoiceRouter.route(text, facts: facts(voice: false, focus: .editable)) {
                XCTFail("no dictation to edit: \(text)")
            }
        }
        if case .dictationEdit = VoiceRouter.route("Geri al", facts: facts(focus: .notEditable, lastDictation: "Ahmed geldi")) {
            XCTFail("with no text field in front 'geri al' is no edit")
        }
        for text in ["raporu hazır yap", "videoyu biraz geri al", "yarınki hatırlatıcıyı sil"] {
            if case .dictationEdit = VoiceRouter.route(text, facts: typing) { XCTFail("not an edit: \(text)") }
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

    func testOpenMisheardClaudeOutsideClaude() {
        for text in ["Claude kodu aç", "Cloud kodu aç", "Cılat aç", "culud başlat", "cılade aç", "kılavu aç", "Kılavu aç.", "kılavuyaç"] {
            guard case .command(.system(.switchToAgent(.claudeCode))) = VoiceRouter.route(
                text, facts: facts(focus: .notEditable, hasTargetApp: false)
            ) else { return XCTFail("\(text) must open Claude without Claude in front") }
        }
    }

    func testOpenCodexAndChatGPTFromVoice() {
        for (text, agent): (String, AgentApp) in [
            ("Kodeksi Aç", .codex), ("Kodeksi aç.", .codex),
            ("Kodeksyaç", .codex), ("Codexiaç", .codex), ("ChatGPTyiaç", .chatGPT),
            ("Codex'i aç", .codex), ("ChatGPT'yi aç", .chatGPT),
            ("ChatGPT aç", .chatGPT), ("Chat GPT'yi aç", .chatGPT),
        ] {
            for focus: TextFocusStatus in [.editable, .notEditable] {
                guard case .command(.system(.switchToAgent(let target))) = VoiceRouter.route(
                    text, facts: facts(focus: focus, hasTargetApp: false)
                ) else { XCTFail("\(text) must open the app"); continue }
                XCTAssertEqual(target, agent, text)
            }
        }
    }

    func testAgentContinuationAcceptsTypingDictationAndCommands() {
        let context = facts(focus: .editable, targetBundleID: "com.anthropic.claudefordesktop")
        for text in ["Şimdi naber nasılsın yaz", "Şimdi selamlar, ben nasılsın yaz."] {
            guard case .typed(let body) = VoiceRouter.route(text, facts: context) else {
                return XCTFail("Explicit writing must survive agent continuation: \(text)")
            }
            XCTAssertFalse(body.hasSuffix("yaz"))
        }
        guard case .spotifyOrConversation = VoiceRouter.route("Bu projedeki hataları birlikte inceleyelim", facts: context) else {
            return XCTFail("Plain speech must reach the dictation fallback")
        }
        guard case .command(.system(.time)) = VoiceRouter.route("Saat kaç", facts: context) else {
            return XCTFail("Commands must still work")
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

    /// Only these may end a Jarvis recording before the usual silence (FastStop).
    func testClearCommandsForFastStop() {
        let context = CommandRegistry.Context()
        for text in ["Saat kaç?", "Müziği durdur.", "Müziği devam ettir.", "Sesi biraz kıs.",
                     "Zamanlayıcı ne kadar kaldı?", "Videoyu durdur"] {
            XCTAssertTrue(CommandRegistry.isClearCommand(text, context: context), text)
        }
        for text in ["", "Müziği", "Ses çok yüksek", "Google'da hava durumu ara",
                     "Claude Code'a yaz merhaba", "Spotify'da Tarkan çal", "Bugün hava çok güzel"] {
            XCTAssertFalse(CommandRegistry.isClearCommand(text, context: context), text)
        }
    }
}
