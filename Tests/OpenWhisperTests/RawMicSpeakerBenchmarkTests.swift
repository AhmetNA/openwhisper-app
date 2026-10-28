import AVFoundation
import XCTest
@testable import OpenWhisper

/// Does "Yalnızca Benim Sesim" still recognize the user on the raw mic? Skipped unless
/// `BENCH_RAWMIC_DIR=~/Library/Application\ Support/OpenWhisper/Recordings BENCH_RAWMIC_MIC=external swift test --filter RawMicSpeakerBenchmark`.
/// Runs the filter on each saved (raw) recording three ways against the stored profile of that
/// mic: as recorded, with the input gain, and through DeepFilterNet as the processed chain does.
/// Window scores land in /tmp/openwhisper-tests.log under `[RawMicBench]` markers.
final class RawMicSpeakerBenchmarkTests: XCTestCase {
    func testRawVersusProcessedScores() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BENCH_RAWMIC_DIR"] else {
            throw XCTSkip("BENCH_RAWMIC_DIR not set")
        }
        let mic = TargetSpeakerMic(rawValue: ProcessInfo.processInfo.environment["BENCH_RAWMIC_MIC"] ?? "external") ?? .external
        guard let profile = try KeychainTargetSpeakerProfileStore(mic: mic).load() else {
            throw XCTSkip("No \(mic) profile")
        }
        let filter = TargetSpeakerFilter(model: FluidAudioTargetSpeakerModel())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".caf") && !$0.contains("partial") }
            .sorted()
        for name in files {
            let raw = try Self.read(URL(fileURLWithPath: dir).appendingPathComponent(name))
            let variants: [(String, [Float])] = [
                ("raw", raw),
                ("gain", raw.map { max(-1, min(1, $0 * AudioSignalProcessor.inputGain)) }),
                ("deepfilter", try Self.deepFiltered(raw)),
            ]
            for (variant, samples) in variants {
                owLog("[RawMicBench] \(name) \(variant)")
                let result = await filter.filter(samples: samples, profile: profile, enabled: true)
                owLog("[RawMicBench] \(name) \(variant) decision=\(result.decision) accepted=\(result.acceptedSampleCount)/\(samples.count)")
            }
        }
    }

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// 16 kHz → 48 kHz → DeepFilterNet → 16 kHz, the rates the live chain runs at.
    private static func deepFiltered(_ samples: [Float]) throws -> [Float] {
        let up = try resample(samples, from: 16_000, to: DeepFilterProcessor.sampleRate)
        guard let processor = DeepFilterProcessor(modelPath: "/Applications/Jarvis.app/Contents/Resources/DeepFilterNet3_onnx.tar.gz") else { throw XCTSkip("DeepFilterNet model unavailable") }
        var out: [Float] = []
        up.withUnsafeBufferPointer { processor.process($0.baseAddress!, count: up.count, into: &out) }
        return try resample(out, from: DeepFilterProcessor.sampleRate, to: 16_000)
    }

    private static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * to / from) + 1024)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
