import Foundation

struct SpeechPreviewCoverage: Sendable {
    var processedSamples = 0
    var lastSpeechSample = 0
}

/// A preview may replace a final decode only for the identical audio prefix followed by
/// VAD-confirmed silence. Speaker masking, resumed speech and unprocessed tails invalidate it.
struct SpeechPreview: Sendable {
    let samples: [Float]
    let language: String
    let modelID: String
    let speechTime: TimeInterval
    let task: Task<String?, Never>

    func matches(_ finalSamples: [Float], language: String, modelID: String,
                 speechTime: TimeInterval, coverage: SpeechPreviewCoverage) -> Bool {
        mismatch(finalSamples, language: language, modelID: modelID, speechTime: speechTime, coverage: coverage) == nil
    }

    /// Why the preview can't stand in for the final decode, or nil when it can.
    func mismatch(_ finalSamples: [Float], language: String, modelID: String,
                  speechTime: TimeInterval, coverage: SpeechPreviewCoverage) -> String? {
        if self.language != language || self.modelID != modelID { return "language or model changed" }
        if self.speechTime != speechTime { return "speech after the preview" }
        if samples.isEmpty || finalSamples.count < samples.count {
            return "final audio shorter (\(finalSamples.count) < \(samples.count) samples)"
        }
        if !finalSamples.starts(with: samples) { return "final audio differs from the previewed prefix" }
        if coverage.processedSamples < finalSamples.count {
            return "VAD hasn't classified the tail (\(coverage.processedSamples)/\(finalSamples.count))"
        }
        if coverage.lastSpeechSample > samples.count {
            return "speech after the previewed audio (\(coverage.lastSpeechSample) > \(samples.count))"
        }
        return nil
    }
}
