import XCTest
@testable import OpenWhisper

final class SystemAudioSessionRecorderTests: XCTestCase {
    private let rate = SystemAudioSessionRecorder.sampleRate

    func testPausesNeverSplitTheSessionIntoSeveralClips() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0.25, count: rate * 2))
        recorder.ingest(Array(repeating: 0, count: rate * 5))
        recorder.ingest(Array(repeating: 0.2, count: rate * 2))

        let samples = recorder.finish()
        XCTAssertNotNil(samples)
        // Both sounds are in the one recording, with the 5 s pause shortened to 1 s.
        XCTAssertEqual(samples?.count, rate * 5)
        XCTAssertEqual(samples?.first, 0.25)
        XCTAssertEqual(samples?.last, 0.2)
    }

    func testShortPausesAreKeptWhole() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0.25, count: rate))
        recorder.ingest(Array(repeating: 0, count: rate * 7 / 10))
        recorder.ingest(Array(repeating: 0.25, count: rate))
        XCTAssertEqual(recorder.finish()?.count, rate * 27 / 10)
    }

    func testTrailingSilenceIsDroppedAndSoftSpeechIsKept() {
        let recorder = SystemAudioSessionRecorder()
        // -46 dBFS: below the "heard" threshold but above the pause threshold → kept.
        recorder.ingest(Array(repeating: 0.005, count: rate * 3))
        recorder.ingest(Array(repeating: 0.25, count: rate))
        recorder.ingest(Array(repeating: 0, count: rate * 60))
        XCTAssertEqual(recorder.finish()?.count, rate * 4)
    }

    func testLeadingSilenceIsDropped() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0, count: rate * 9 / 10))
        recorder.ingest(Array(repeating: 0.25, count: rate))
        recorder.ingest(Array(repeating: 0, count: rate * 9 / 10))

        let samples = recorder.finish()
        XCTAssertEqual(samples?.count, rate)
        XCTAssertEqual(samples?.first, 0.25)
        XCTAssertEqual(samples?.last, 0.25)
    }

    func testSilentSessionReturnsNothingAndRecorderResets() {
        let recorder = SystemAudioSessionRecorder()
        recorder.ingest(Array(repeating: 0, count: rate * 10))
        recorder.ingest(Array(repeating: 0.3, count: rate / 10))
        XCTAssertNil(recorder.finish())

        recorder.ingest(Array(repeating: 0.3, count: rate))
        XCTAssertEqual(recorder.finish()?.count, rate)
        XCTAssertNil(recorder.finish())
    }

    func testSpokenSecondsSkipHallucinatedSegmentsAndGaps() {
        // The 16 s voice message that came back as only this credit: nothing was transcribed.
        XCTAssertEqual(
            WhisperTranscriber.spokenSeconds(in: [(start: 0, end: 15.9, text: "<|startoftranscript|><|tr|><|transcribe|><|0.00|> Altyazı M.K.<|15.9|>")]),
            0
        )
        // A loop that swallowed a window has no length, so the gap is not counted as done.
        let spoken = WhisperTranscriber.spokenSeconds(in: [
            (start: 0, end: 4, text: "<|0.00|> Hakkımızda kısmında ilk sayfada<|4.00|>"),
            (start: 4.5, end: 4.5, text: "<|4.50|> Altında da yeni nesil<|4.50|>"),
            (start: 30, end: 40, text: "<|0.00|> Yüzlerce öğrenciye hizmet verildi<|10.00|>"),
        ])
        XCTAssertEqual(spoken, 14, accuracy: 0.01)
    }

    func testFinishedReportSaysWhatWasTranscribedAndCopied() {
        XCTAssertEqual(
            SystemAudioReport.finished(elapsed: 49.9, audioSeconds: 49.3, spokenSeconds: 47, wordCount: 120, copied: true),
            L("Ses 49 sn · Çevrilen 47 sn · 120 kelime · Panoya kopyalandı", "Audio 49 s · Transcribed 47 s · 120 words · Copied")
        )
        XCTAssertEqual(
            SystemAudioReport.finished(elapsed: 90, audioSeconds: 60, spokenSeconds: 20, wordCount: 30, copied: true),
            L("Kayıt 1 dk 30 sn · Ses 1 dk · Çevrilen 20 sn · 30 kelime · Eksik olabilir · Panoya kopyalandı",
              "Recorded 1 min 30 s · Audio 1 min · Transcribed 20 s · 30 words · May be incomplete · Copied")
        )
    }

    func testChunksStartWhereTheSoundComesBack() {
        let sound = [Float](repeating: 0.25, count: rate * 20)
        let chunks = AudioSegmentation.systemAudioChunks(
            from: [Float](repeating: 0, count: rate) + sound + [Float](repeating: 0, count: rate) + sound
        )
        XCTAssertEqual(chunks, [rate..<(rate * 21), (rate * 22)..<(rate * 42)])
    }

    func testChunksStayInsideWhispersWindowWithoutAnyPause() {
        let chunks = AudioSegmentation.systemAudioChunks(from: [Float](repeating: 0.25, count: rate * 60))
        XCTAssertEqual(chunks, [0..<(rate * 28), (rate * 28)..<(rate * 56), (rate * 56)..<(rate * 60)])
    }

    func testVerySoftRecordingStillHasChunks() {
        // -46 dBFS throughout: kept by the recorder, so it must reach Whisper too.
        let samples = [Float](repeating: 0.005, count: rate * 3)
        XCTAssertEqual(AudioSegmentation.systemAudioChunks(from: samples), [0..<(rate * 3)])
    }

    func testSparseTextIsReportedAsPossiblyIncomplete() {
        XCTAssertEqual(
            SystemAudioReport.finished(elapsed: 15, audioSeconds: 14.4, spokenSeconds: 14.4, wordCount: 17, copied: true),
            L("Ses 14 sn · Çevrilen 14 sn · 17 kelime · Eksik olabilir · Panoya kopyalandı",
              "Audio 14 s · Transcribed 14 s · 17 words · May be incomplete · Copied")
        )
    }
}
