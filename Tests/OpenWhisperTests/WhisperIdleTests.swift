import XCTest
@testable import OpenWhisper

@MainActor
final class WhisperIdleTests: XCTestCase {
    func testKeyboardSessionsAlsoKeepModelWarmBetweenCommands() async {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.wakeWordEnabled = previous }
        app.wakeWordEnabled = false
        app.modelLoaded = true
        app.lastWhisperActivity = Date().addingTimeInterval(-30)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertTrue(app.modelLoaded)
        XCTAssertFalse(app.whisperSuspendedForIdle)
        app.lastWhisperActivity = Date().addingTimeInterval(-61)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertFalse(app.modelLoaded)
        XCTAssertTrue(app.whisperSuspendedForIdle)
    }

    func testWakeEnabledKeepsWarmWhisperThenReleasesAfterGrace() async {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.wakeWordEnabled = previous }
        app.wakeWordEnabled = true
        app.modelLoaded = true
        app.lastWhisperActivity = Date()
        await app.suspendIdleWhisperIfPossible()
        XCTAssertTrue(app.modelLoaded)
        XCTAssertFalse(app.whisperSuspendedForIdle)
        app.lastWhisperActivity = Date().addingTimeInterval(-61)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertFalse(app.modelLoaded)
        XCTAssertTrue(app.whisperSuspendedForIdle)
    }

    func testIdleReleaseAndEveryActiveConsumerBlocksRelease() async {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.whisperSuspendedForIdle = false; app.wakeWordEnabled = previous }
        app.wakeWordEnabled = false
        app.modelLoaded = true
        XCTAssertTrue(app.canSuspendIdleWhisper)
        app.recordingState = .recording
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.recordingState = .idle
        app.pendingTranscriptionCount = 1
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.pendingTranscriptionCount = 0
        app.systemAudioIsTranscribing = true
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.systemAudioIsTranscribing = false
        app.systemAudioEnabled = true
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.systemAudioEnabled = false
        app.replayingRecordingID = UUID()
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.replayingRecordingID = nil
        app.wakeCandidateVerifying = true
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.wakeCandidateVerifying = false
        app.activeWhisperWakeChecks = 1
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.activeWhisperWakeChecks = 0
        app.modelLoading = true
        XCTAssertFalse(app.canSuspendIdleWhisper)
        app.modelLoading = false
        await app.suspendIdleWhisperIfPossible()
        XCTAssertFalse(app.modelLoaded)
        XCTAssertTrue(app.whisperSuspendedForIdle)
        XCTAssertNil(app.whisperUnloadTask)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertTrue(app.whisperSuspendedForIdle)
    }
    /// Opt-in local integration probe: actual installed Turbo, no microphone or text delivery.
    func testRealWhisperReleaseAndConcurrentResume() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_REAL_WHISPER"] == "1" else {
            throw XCTSkip("Requires the locally installed Turbo model")
        }
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.whisperSuspendedForIdle = false; app.wakeWordEnabled = previous }
        app.wakeWordEnabled = false
        await app.loadModel()
        XCTAssertTrue(app.modelLoaded)
        func footprint(_ phase: String) throws {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            process.arguments = ["-p", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .first { $0.contains("Footprint:") } ?? "unavailable"
            print("WHISPER_IDLE_PROBE \(phase): \(line)")
        }
        try footprint("loaded")
        app.lastWhisperActivity = Date().addingTimeInterval(-61)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertFalse(app.modelLoaded)
        XCTAssertTrue(app.whisperSuspendedForIdle)
        try footprint("released")
        let start = Date()
        async let first: Void = app.resumeIdleWhisperIfNeeded()
        async let second: Void = app.resumeIdleWhisperIfNeeded()
        _ = await (first, second)
        print("WHISPER_IDLE_PROBE concurrent resume seconds: \(Date().timeIntervalSince(start))")
        XCTAssertTrue(app.modelLoaded)
        XCTAssertFalse(app.whisperSuspendedForIdle)
        XCTAssertNil(app.transcriptionModelLoadTask)
        try footprint("resumed")
        app.lastWhisperActivity = Date().addingTimeInterval(-61)
        await app.suspendIdleWhisperIfPossible()
        XCTAssertFalse(app.modelLoaded)
    }

}
