import AVFoundation
import FluidAudio
import XCTest
@testable import OpenWhisper

final class DiarizationReplayProbeTests: XCTestCase {
    func testSavedActivity() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIARIZATION_REPLAY_DIR"] else { throw XCTSkip("Opt-in local recording diagnostic") }
        let config = SortformerConfig.default
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .all)
        let diarizer = SortformerDiarizer(config: config, postProcessingConfig: .default)
        diarizer.initialize(models: models)
        let dir = URL(fileURLWithPath: path)
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "log" }).sorted(by: { $0.path < $1.path }) {
            let log = try String(contentsOf: url)
            guard log.contains("diarization failed") else { continue }
            let file = try AVAudioFile(forReading: url.deletingPathExtension().appendingPathExtension("caf"))
            guard file.processingFormat.sampleRate == 16000, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let timeline = try diarizer.processComplete(samples)
            var runs: [Int] = []; var length = 0; var last: Int? = nil
            var activeFrames = 0
            var activity: [TargetSpeakerActivityFrame] = []
            for i in 0..<timeline.numFrames {
                let slots = (0..<config.numSpeakers).filter { timeline.probability(speaker: $0, frame: i) >= 0.5 }
                activity.append(TargetSpeakerActivityFrame(frameIndex: i, startTime: Double(i)*0.08,
                    endTime: min(Double(i+1)*0.08, Double(samples.count)/16000), probabilities: [], activeSpeakerSlots: slots))
                if slots.count == 1 {
                    activeFrames += 1
                    if last == slots[0] { length += 1 } else { if length > 0 { runs.append(length) }; length = 1; last = slots[0] }
                } else { if length > 0 { runs.append(length) }; length = 0; last = nil }
            }
            if length > 0 { runs.append(length) }
            let windows = TargetSpeakerIdentityWindows.make(frames: activity, audioSampleCount: samples.count)
            print("REPLAY windows=\(windows.count) pooled=\(windows.filter { $0.ranges.count > 1 }.count)")
            print("REPLAY \(url.lastPathComponent) duration=\(Double(samples.count)/16000) soloFrames=\(activeFrames) runsSeconds=\(runs.map { Double($0)*0.08 })")
        }
    }
}
