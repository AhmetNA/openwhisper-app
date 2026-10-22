import XCTest
@testable import OpenWhisper

/// A request written in the Jarvis panel goes where a "Hey Jarvis" transcript goes, without the
/// speech-only checks, and is answered rather than pasted back into the field behind the panel.
@MainActor
final class TypedRequestTests: XCTestCase {
    private func typedSession() -> RecordingTranscriptionSession {
        let session = RecordingTranscriptionSession(
            id: 1, targetApp: nil, targetSpeakerEnabled: false, targetSpeakerProfile: nil,
            pasteContext: PasteContext.initial(targetApp: nil)
        )
        session.trigger = .typed
        session.isVoiceCommand = true
        return session
    }

    func testTypedSessionTakesCommandsAndChatLikeJarvis() {
        let session = typedSession()
        XCTAssertTrue(session.acceptsCommands)
        XCTAssertFalse(session.takesOnlyCommands)
        XCTAssertFalse(session.appliesSpeechChecks)
        XCTAssertFalse(TargetSpeakerOutputGate.shouldSkipPostProcessing(
            featureEnabled: session.targetSpeakerEnabled, acceptedSampleCount: session.acceptedTargetSpeechSamples
        ))
    }

    func testVoiceSessionsKeepTheSpeechChecks() {
        let session = typedSession()
        for trigger: RecordingTrigger in [.wakeWord, .jarvisKey, .followUp, .fnHold] {
            session.trigger = trigger
            XCTAssertTrue(session.appliesSpeechChecks, "\(trigger)")
        }
    }

    func testTypedRequestIsNeverRoutedAsDictation() {
        XCTAssertEqual(RecordingTranscriptionSession.routingFocus(trigger: .typed, captured: .editable, simulated: nil),
                       .notEditable)
        XCTAssertEqual(RecordingTranscriptionSession.routingFocus(trigger: .typed, captured: .unknown, simulated: .editable),
                       .notEditable)
        XCTAssertEqual(RecordingTranscriptionSession.routingFocus(trigger: .wakeWord, captured: .editable, simulated: nil),
                       .editable)
        XCTAssertEqual(RecordingTranscriptionSession.routingFocus(trigger: .wakeWord, captured: .editable, simulated: .unknown),
                       .unknown)
    }

    func testTypedGreetingIsAnsweredEvenOverATextField() {
        let session = typedSession()
        let facts = VoiceRouter.Facts(
            isVoiceCommand: session.isVoiceCommand, acceptsCommands: session.acceptsCommands,
            focus: RecordingTranscriptionSession.routingFocus(trigger: .typed, captured: .editable, simulated: nil),
            hasTargetApp: true, targetBundleID: nil, pendingDeletion: false, commandAmongPlayback: false
        )
        guard case .greeting = VoiceRouter.route("Günaydın", facts: facts) else {
            return XCTFail("a typed greeting is answered")
        }
    }
}
