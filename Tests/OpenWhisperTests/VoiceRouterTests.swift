import XCTest
@testable import OpenWhisper

/// The session facts `RouteCorpusTests` keeps fixed: focus, a pending deletion, no app in front.
@MainActor
final class VoiceRouterTests: XCTestCase {
    private func facts(voice: Bool = true, focus: TextFocusStatus = .unknown, hasTargetApp: Bool = true,
                       targetBundleID: String? = nil, pendingDeletion: Bool = false) -> VoiceRouter.Facts {
        VoiceRouter.Facts(isVoiceCommand: voice, acceptsCommands: true, focus: focus,
                          hasTargetApp: hasTargetApp, targetBundleID: targetBundleID,
                          pendingDeletion: pendingDeletion)
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

    func testSendWithNoAppInFront() {
        guard case .agentWithoutForeground = VoiceRouter.route("bunu düzelt gönder", facts: facts(hasTargetApp: false)) else {
            return XCTFail("a Jarvis send with nothing in front is refused")
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
}
