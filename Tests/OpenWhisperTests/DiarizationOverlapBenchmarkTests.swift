import AVFoundation
import WhisperKit
import XCTest
@testable import OpenWhisper

/// Whether the speaker half of diarization really runs alongside Whisper or just contends for
/// the Neural Engine. Skipped unless
/// `BENCH_DIAR_DIR=~/Library/Application\ Support/OpenWhisper/Recordings swift test --filter DiarizationOverlapBenchmark`.
/// Joins the saved .caf recordings there into ~25 s and times the decode and the speaker
/// analysis one after the other, then together. A random profile is enough: the analysis does
/// all its model work before it finds no matching slot.
final class DiarizationOverlapBenchmarkTests: XCTestCase {
    func testSequentialVersusParallel() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BENCH_DIAR_DIR"] else {
            throw XCTSkip("BENCH_DIAR_DIR not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".caf") && !$0.contains("partial") }
            .sorted()
        var audio: [Float] = []
        for name in files where audio.count < 25 * 16_000 {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: dir).appendingPathComponent(name))
            guard file.processingFormat.sampleRate == 16_000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try file.read(into: buffer)
            audio += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        print("[Bench] audio \(Double(audio.count) / 16_000) s from \(files.count) files")

        let model = ProcessInfo.processInfo.environment["BENCH_WHISPER_MODEL"] ?? "large-v3-v20240930_turbo"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)")
        let whisper = try await WhisperKit(modelFolder: folder.path, verbose: false, prewarm: true, load: true, download: false)
        let options = DecodingOptions(language: "tr", temperature: 0, wordTimestamps: true)

        let diarization = FluidAudioTargetSpeakerDiarizationService()
        try await diarization.prepare(progressHandler: nil)
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerDiarizationService.modelIdentifier,
            embeddings: [(0..<256).map { _ in Float.random(in: -1...1) }]
        )
        let analyze = { _ = try? await diarization.analyzeSpeakers(audioData: audio, profile: profile, audioProcessingMode: .off) }

        // Warm both once so the first timed run doesn't pay model compilation.
        _ = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        await analyze()

        for round in 1...6 {
            var start = Date()
            _ = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            let whisperAlone = Date().timeIntervalSince(start)
            start = Date()
            await analyze()
            let analysisAlone = Date().timeIntervalSince(start)

            start = Date()
            async let speakers: Void = analyze()
            _ = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            await speakers
            let together = Date().timeIntervalSince(start)
            print(String(format: "[Bench] round %d: whisper %.2f s + analysis %.2f s = %.2f s sequential, %.2f s parallel",
                         round, whisperAlone, analysisAlone, whisperAlone + analysisAlone, together))
        }
    }
}
