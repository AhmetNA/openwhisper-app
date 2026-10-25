import XCTest
@testable import OpenWhisper

final class ConversationDestinationDecisionTests: XCTestCase {
    func testVoiceNeedsStrongDestinationBeforePasting() {
        for score: Int? in [nil, 31, 50, 69] {
            XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: .editable, score: score, minScore: 70), .clarify)
        }
        XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: .editable, score: 30, minScore: 70), .type)
        XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: .editable, score: 70, minScore: 70), .chat)
        XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: .unknown, score: 10, minScore: 70), .clarify)
        XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: .notEditable, score: nil, minScore: 70), .chat)
    }

    func testContinuationIgnoresChangedEditorFocusAndMissingScore() {
        for focus in [TextFocusStatus.editable, .notEditable, .unknown] {
            XCTAssertEqual(JarvisAddressee.voiceRoute(focusStatus: focus, score: nil, minScore: 70,
                                                     continuingConversation: true), .chat)
        }
        // Fn dictation's established policy remains independent of a prior Jarvis reply.
        XCTAssertEqual(JarvisAddressee.defaultRoute(focusStatus: .editable, score: nil, minScore: 70), .type)
    }

    func testClarificationDoesNotTreatYesAsDestinationOrSendARequest() {
        for text in ["Sana söyledim.", "Sana sordum", "Bana cevap ver"] {
            XCTAssertEqual(JarvisAddressee.clarificationChoice(text), .chat)
        }
        for text in ["Bunu yaz", "Buraya yaz.", "Dikte"] {
            XCTAssertEqual(JarvisAddressee.clarificationChoice(text), .type)
        }
        for text in ["İptal", "Boş ver", "Hayır"] {
            XCTAssertEqual(JarvisAddressee.clarificationChoice(text), .cancel)
        }
        for text in ["", "Evet", "Tamam", "Bunu yaz ve gönder", "Buraya yaz yeni bir istek", "sana söyledim mi bilmiyorum"] {
            XCTAssertNil(JarvisAddressee.clarificationChoice(text), text)
        }
    }
}

@MainActor
final class ConversationDestinationRoutingTests: XCTestCase {
    func testWakeRecoversObservedNamesOnlyForWholeGreetingOrWorkRequest() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .editable,
                                      hasTargetApp: true, targetBundleID: "com.openai.codex", greetingAfterWake: true)
        for text in ["Cans, ne haber, nasılsın?", "Acariz nerede kalmıştık?", "Hey Cariz günaydın",
                     "Tecarisi son işleri özetle", "Tecaviz. En son neler yaptık özetle.",
                     "Sıra Cervis sonuçları özetle.", "Nerede kalmıştık?", "Günaydın"] {
            guard case .greeting = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Expected work briefing: \(text)"); continue
            }
        }
        for text in ["Cans hakkında ne düşünüyorsun", "Anneme günaydın", "Günaydın dediğimde metni yaz"] {
            if case .greeting = VoiceRouter.route(text, facts: facts) { XCTFail(text) }
        }
        XCTAssertNil(JarvisReply.greeting(in: "Cans ne haber nasılsın"))
    }

    func testExplicitDestinationWinsEvenInConversation() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .editable,
                                      hasTargetApp: true, targetBundleID: "com.openai.codex", greetingAfterWake: true)
        guard case .typed("Cans ne haber nasılsın") = VoiceRouter.route("Buraya yaz Cans ne haber nasılsın", facts: facts) else {
            return XCTFail("Explicit dictation must retain the original spelling")
        }
        guard case .agent = VoiceRouter.route("Codex'e yaz günaydın gönder", facts: facts) else {
            return XCTFail("Explicit agent message must win")
        }
        let keys = VoiceRouter.Facts(isVoiceCommand: false, acceptsCommands: true, focus: .editable, hasTargetApp: true)
        if case .greeting = VoiceRouter.route("Cans ne haber nasılsın", facts: keys) { XCTFail("Fn must keep dictation") }
    }

    func testActualSessionTriggerFeedsWakeRecoveryAndClarificationExpires() {
        let session = RecordingTranscriptionSession(id: 1, targetApp: nil, targetSpeakerEnabled: false, targetSpeakerProfile: nil)
        session.isVoiceCommand = true
        session.trigger = .wakeWord
        XCTAssertTrue(session.recoversWakeGreeting)
        session.trigger = .followUp
        XCTAssertFalse(session.recoversWakeGreeting)
        session.isConversationFollowUp = true
        XCTAssertTrue(session.recoversWakeGreeting)
        session.isVoiceCommand = false
        session.trigger = .fnHold
        XCTAssertFalse(session.recoversWakeGreeting)
        let request = RecordingTranscriptionSession.AddresseeClarification(text: "ilk istek", targetApp: nil, pasteContext: session.pasteContext)
        XCTAssertTrue(request.isFresh(now: request.createdAt.addingTimeInterval(5)))
        XCTAssertFalse(request.isFresh(now: request.createdAt.addingTimeInterval(20)))
        session.continuation.finish()
    }
}
