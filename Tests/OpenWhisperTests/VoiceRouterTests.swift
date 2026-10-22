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
