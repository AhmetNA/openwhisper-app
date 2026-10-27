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
        guard self.language == language, self.modelID == modelID, self.speechTime == speechTime,
              !samples.isEmpty, finalSamples.count >= samples.count,
              finalSamples.starts(with: samples),
              coverage.processedSamples >= finalSamples.count,
              coverage.lastSpeechSample <= samples.count else { return false }
        return true
    }
}
