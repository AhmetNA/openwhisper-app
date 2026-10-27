import XCTest
@testable import OpenWhisper

@MainActor
final class PendingWhisperWakeTests: XCTestCase {
    func testDirectSpeakerMatchSurvivesWrongWhisperWakeText() async {
        let result = await PendingWhisperWake.verifyWake(isDirect: true, speakerMatched: true, score: 0.3) {
            XCTFail("A matched direct wake must not be vetoed by the cold-model transcript")
            return false
        }
        XCTAssertTrue(result)
    }

    func testCandidateAndUnmatchedDirectWakeStillRequireWords() async {
        for (direct, matched) in [(false, true), (true, false), (false, false)] {
            var verified = false
            let result = await PendingWhisperWake.verifyWake(isDirect: direct, speakerMatched: matched, score: 0.3) {
                verified = true
                return false
            }
            XCTAssertTrue(verified)
            XCTAssertFalse(result)
        }
    }

    func testStrongDirectWakeSkipsColdWordCheck() async {
        let result = await PendingWhisperWake.verifyWake(isDirect: true, speakerMatched: false, score: 0.65) {
            XCTFail("A strong direct wake must not be vetoed by the cold-model transcript")
            return false
        }
        XCTAssertTrue(result)
    }

    func testStrongCandidateStillRequiresWords() async {
        var verified = false
        let result = await PendingWhisperWake.verifyWake(isDirect: false, speakerMatched: false, score: 0.65) {
            verified = true
            return false
        }
        XCTAssertTrue(verified)
        XCTAssertFalse(result)
    }

    func testLoadsBeforeVerificationAndAcceptsOnlyAfterBoth() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        var steps: [String] = []
        let result = await request.evaluate(load: {
            steps.append("load")
            XCTAssertFalse(request.accepted)
            return true
        }, verify: {
            steps.append("verify")
            XCTAssertFalse(request.accepted)
            return true
        }, now: { 11 })
        XCTAssertTrue(result)
        XCTAssertTrue(request.accepted)
        XCTAssertEqual(steps, ["load", "verify"])
    }

    func testCancelledDuringLoadingNeverVerifiesOrAccepts() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        let result = await request.evaluate(load: {
            request.cancel()
            return true
        }, verify: { XCTFail("stale wake must not verify"); return true }, now: { 11 })
        XCTAssertFalse(result)
        XCTAssertFalse(request.accepted)
    }

    func testCancelledDuringVerificationNeverAccepts() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        let result = await request.evaluate(load: { true }, verify: {
            request.cancel()
            return true
        }, now: { 11 })
        XCTAssertFalse(result)
    }

    func testExpiredLoadNeverVerifies() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        var time: TimeInterval = 11
        let result = await request.evaluate(load: { time = 25; return true },
            verify: { XCTFail("expired wake must not verify"); return true }, now: { time })
        XCTAssertFalse(result)
    }

    func testSlowVerificationAndLoadFailureAreRejected() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        var time: TimeInterval = 11
        let expired = await request.evaluate(load: { true }, verify: { time = 26; return true }, now: { time })
        XCTAssertFalse(expired)
        let failed = await request.evaluate(load: { false }, verify: { XCTFail(); return true }, now: { 11 })
        XCTAssertFalse(failed)
    }

    func testFalseWakeCannotOpenSessionAndAcceptedWakeCanStillBeCancelled() async {
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil, now: 10)
        let result = await request.evaluate(load: { true }, verify: { false }, now: { 11 })
        XCTAssertFalse(result)
        let accepted = await request.evaluate(load: { true }, verify: { true }, now: { 11 })
        XCTAssertTrue(accepted)
        request.cancel()
        XCTAssertFalse(request.isValid(at: 11))
        XCTAssertFalse(request.accepted)
    }

    func testDisablingWakeRevokesPendingRequestWithoutLoadingModel() {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.wakeWordEnabled = previous }
        app.wakeWordEnabled = true
        app.whisperSuspendedForIdle = true
        let request = PendingWhisperWake(inputUID: "mic", clipID: nil)
        app.pendingWhisperWake = request
        app.wakeWordEnabled = false
        XCTAssertNil(app.pendingWhisperWake)
        XCTAssertFalse(request.isValid())
        XCTAssertNil(app.transcriptionModelLoadTask)
    }
    func testRejectedWakeDoesNotKeepLargeModelWarm() {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.wakeWordEnabled = previous }
        app.wakeWordEnabled = true
        app.modelLoaded = true
        app.lastWhisperActivity = Date()
        app.pendingWhisperWake = PendingWhisperWake(inputUID: "mic", clipID: nil)
        app.cancelPendingWhisperWake(reason: "test rejection", retryDelay: 10)
        XCTAssertTrue(app.canSuspendIdleWhisper)
        XCTAssertGreaterThan(app.whisperWakeRetryAfter, ProcessInfo.processInfo.systemUptime)
    }

}
