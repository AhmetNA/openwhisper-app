import XCTest
@testable import OpenWhisper

@MainActor
final class UnrecognizedRecordingTests: XCTestCase {
    func testExplicitDictationReportsFailureEvenWithUnprocessedAudio() async {
        let app = AppState()
        let session = RecordingTranscriptionSession(id: 1, targetApp: nil, targetSpeakerEnabled: false, targetSpeakerProfile: nil)
        session.bypassAudioProcessing = true
        await app.reportUnrecognizedRecording(session)
        XCTAssertNotNil(app.lastError)
        XCTAssertEqual(app.flowBarMessage, app.lastError)
        XCTAssertTrue(app.flowBarMessage?.contains("metin çıkarılamadı") == true)
        app.dismissFlowBarMessage()
    }

    func testPassiveFollowUpAndCancelledSessionStayQuiet() async {
        for cancelled in [false, true] {
            let app = AppState()
            let session = RecordingTranscriptionSession(id: 1, targetApp: nil, targetSpeakerEnabled: false, targetSpeakerProfile: nil)
            session.isCancelled = cancelled
            session.followsCommand = !cancelled
            await app.reportUnrecognizedRecording(session)
            XCTAssertNil(app.flowBarMessage)
        }
    }
}
