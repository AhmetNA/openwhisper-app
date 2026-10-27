import XCTest
import AVFoundation
import FluidAudio
@testable import OpenWhisper

final class SpeechPreviewTests: XCTestCase {
    /// Local, opt-in replay: no microphone, routing, network service or playback side effects.
    func testInstalledTurboPreviewOnRecordedCommand() async throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_PREVIEW_TEST_CAF"] else {
            throw XCTSkip("Set JARVIS_PREVIEW_TEST_CAF to a local 16 kHz command recording")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
        }
        let beforeStop = Array(samples.dropLast(12_800))
        let decoder = WhisperTranscriber()
        try await decoder.loadModel(name: TranscriptionModelRegistry.defaultModelID) { _ in }
        let started = Date()
        let preview = try await decoder.previewTranscription(audioData: beforeStop, language: "tr")
        let previewSeconds = Date().timeIntervalSince(started)
        let finalStart = Date()
        let final = try await decoder.transcribe(audioData: samples, language: "tr")
        let finalSeconds = Date().timeIntervalSince(finalStart)
        let warmStart = Date()
        let warmPreview = try await decoder.previewTranscription(audioData: beforeStop, language: "tr")
        let warmSeconds = Date().timeIntervalSince(warmStart)
        await decoder.unloadModel()
        XCTAssertNotNil(preview, "Fixture must have a confident preview")
        XCTAssertEqual(preview, final, "Preview must preserve the entire recorded command")
        XCTAssertEqual(warmPreview, final)

        let detector = SmartTurnEndpointDetector(startTime: ProcessInfo.processInfo.systemUptime)
        detector.feed(samples)
        detector.finishForPreview(with: samples)
        let coverage = await detector.completedPreviewCoverage()
        let cached = SpeechPreview(samples: beforeStop, language: "tr", modelID: "turbo", speechTime: 10,
                                   task: Task { preview })
        let reusable = cached.matches(samples, language: "tr", modelID: "turbo", speechTime: 10,
                                      coverage: coverage)
        print("PREVIEW_REPLAY coldPreviewSeconds=\(previewSeconds) warmPreviewSeconds=\(warmSeconds) finalDecodeSeconds=\(finalSeconds) reusable=\(reusable) samples=\(samples.count) classified=\(detector.previewCoverage.processedSamples) vadBatch=\(VadManager.chunkSize)")
        XCTAssertTrue(reusable, "Recorded silence should be covered by VAD; otherwise use final decode")
    }

    private let prefix: [Float] = [0.2, -0.1, 0.04, 0]

    private func matches(_ samples: [Float], processed: Int, lastSpeech: Int = 3,
                         language: String = "tr", model: String = "turbo", speechTime: Double = 10) -> Bool {
        SpeechPreview(samples: prefix, language: "tr", modelID: "turbo", speechTime: 10,
                      task: Task { "Sesi kıs" })
            .matches(samples, language: language, modelID: model, speechTime: speechTime,
                     coverage: .init(processedSamples: processed, lastSpeechSample: lastSpeech))
    }

    func testConfirmedSilenceCanReuseTheWholePreview() {
        XCTAssertTrue(matches(prefix + [0.01, -0.01, 0], processed: 7))
        XCTAssertTrue(matches(prefix + [0.001], processed: 5))
    }

    func testResumedSpeechAndChangedSpeakerMaskNeverReuse() {
        XCTAssertFalse(matches(prefix + [0.1], processed: 5, lastSpeech: 5))
        XCTAssertFalse(matches([0, -0.1, 0.04, 0], processed: 4))
        XCTAssertFalse(matches(prefix, processed: 4, speechTime: 11))
    }

    func testUnclassifiedTailAndTruncatedRecordingNeverReuse() {
        XCTAssertFalse(matches(prefix + [0.1], processed: 4))
        XCTAssertFalse(matches(prefix + [0.001], processed: 4))
        XCTAssertFalse(matches(prefix + Array(repeating: 0, count: 512), processed: 4))
        XCTAssertFalse(matches(Array(prefix.dropLast()), processed: 4))
        XCTAssertFalse(matches(prefix, processed: 3))
    }

    func testChangedLanguageOrModelNeverReuse() {
        XCTAssertFalse(matches(prefix, processed: 4, language: "en"))
        XCTAssertFalse(matches(prefix, processed: 4, model: "other"))
    }

    func testBusyPreviewIsSkippedAndFinalWorkWaitsForTheSlot() async throws {
        let gate = TranscriptionWorkGate()
        let latch = PreviewTestLatch()
        let entered = expectation(description: "preview entered")
        let preview = Task {
            try await gate.preview {
                entered.fulfill()
                await latch.wait()
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let skipped = try await gate.preview { XCTFail("must not run a second preview"); return 2 }
        XCTAssertNil(skipped)
        let final = Task { await gate.run { await latch.isOpen } }
        await latch.open()
        let first = try await preview.value
        let finishedAfterRelease = await final.value
        XCTAssertEqual(first, 1)
        XCTAssertTrue(finishedAfterRelease)
    }

    func testFailureReleasesTheModelSlot() async throws {
        enum Failure: Error { case expected }
        let gate = TranscriptionWorkGate()
        do {
            let _: Int? = try await gate.preview { throw Failure.expected }
            XCTFail("expected failure")
        } catch Failure.expected {}
        let result = await gate.run { 42 }
        XCTAssertEqual(result, 42)
    }
}

private actor PreviewTestLatch {
    var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { isOpen = true; waiter?.resume(); waiter = nil }
}
