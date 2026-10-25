import XCTest
@testable import OpenWhisper

final class SpeechDiagnosticsTests: XCTestCase {
    func testNoActionHasExplicitReasonAndDoesNotClaimSuccess() {
        let outcome = SpeechOutcome()
        outcome.record("output.skipped", ["reason": "speaker_gate_rejected"])
        XCTAssertEqual(outcome.summary["assessment"], "no_action_result_reported")
        XCTAssertTrue(outcome.summary["reasons"]!.contains("speaker_gate_rejected"))
        XCTAssertEqual(outcome.summary["deliveries"], "none_reported")
    }

    func testRouteSelectionAloneIsNotAnExecutedAction() {
        let outcome = SpeechOutcome()
        outcome.record("route.selected", ["route": "spotify"])
        XCTAssertEqual(outcome.summary["assessment"], "no_action_result_reported")
        XCTAssertTrue(outcome.summary["reasons"]!.contains("without_output"))
    }

    func testCallbackRecordsFailuresAndRepliesInOwningSession() {
        let first = SpeechOutcome()
        let second = SpeechOutcome()
        SpeechDiagnostics.$outcome.withValue(second) {
            SpeechDiagnostics.withTrace("first", recording: nil, outcome: first) {
                SpeechDiagnostics.event("delivery.result", ["outcome": "failed"])
                SpeechDiagnostics.event("reply.result", ["outcome": "skipped", "reason": "voice_replies_disabled"])
            }
        }
        XCTAssertTrue(first.summary["deliveries"]!.contains("failed"))
        XCTAssertTrue(first.summary["replies"]!.contains("voice_replies_disabled"))
        XCTAssertEqual(second.summary["deliveries"], "none_reported")
    }

    func testLongMultilineTranscriptRemainsLosslessOnOneLogLine() throws {
        let original = String(repeating: "Türkçe \"alıntı\"\\yol\nİkinci satır 😃\t", count: 1000)
        let encoded = SpeechDiagnostics.json(["text": original])
        XCTAssertFalse(encoded.contains("\n"))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded["text"], original)
    }

    func testCallbackRebindsBothRecordingAndSpeechIDs() {
        let recording = UUID()
        SpeechDiagnostics.withTrace("callback", recording: recording) {
            XCTAssertEqual(SpeechDiagnostics.session, "callback")
            XCTAssertEqual(VoiceTrace.current, recording)
        }
        XCTAssertNil(SpeechDiagnostics.session)
        XCTAssertNil(VoiceTrace.current)
    }

    func testConcurrentSessionsAndChildTasksKeepSeparateContext() async {
        async let first: String = SpeechDiagnostics.$session.withValue("first") {
            await SpeechDiagnostics.$batch.withValue(1) {
                await Task { SpeechDiagnostics.context }.value
            }
        }
        async let second: String = SpeechDiagnostics.$session.withValue("second") {
            await SpeechDiagnostics.$batch.withValue(2) {
                await Task { SpeechDiagnostics.context }.value
            }
        }
        let (a, b) = await (first, second)
        XCTAssertEqual(a, "[speech=first batch=1] ")
        XCTAssertEqual(b, "[speech=second batch=2] ")
        XCTAssertEqual(SpeechDiagnostics.context, "")
    }
}
