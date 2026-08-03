import Foundation
import Accelerate

/// Joins transcript batches from one uninterrupted dictation. The microphone remains one
/// recording; AudioEngine emits roughly three-minute batches and WhisperKit handles its own
/// 30-second model windows inside each batch.
struct AudioSegmentation {
    static let sampleRate = 16_000
    /// A batch is intentionally much longer than Whisper's model window. This lets WhisperKit
    /// keep its own seek/timestamp context instead of making the app concatenate many short
    /// decoder calls after recording has already ended.
    static let preferredDuration = 180
    static let maximumDuration = 180
    static let overlapDuration = 1

    struct Segment: Sendable {
        let samples: ArraySlice<Float>
        /// Number of leading samples duplicated from the preceding segment.
        let overlapSampleCount: Int
    }

    /// Uses a conservative 500 ms low-energy run near the three-minute point when one exists.
    /// If continuous speech/noise makes that unsafe, the hard limit is used and the following
    /// batch includes one second of preceding audio.
    static func makeSegments(from samples: [Float]) -> [Segment] {
        guard !samples.isEmpty else { return [] }

        let preferred = preferredDuration * sampleRate
        let maximum = maximumDuration * sampleRate
        let overlap = overlapDuration * sampleRate
        var segments: [Segment] = []
        var start = 0

        while samples.count - start > maximum {
            let preferredCut = min(start + preferred, samples.count)
            let hardCut = min(start + maximum, samples.count)
            let cut = preferredSilenceCut(in: samples, preferredCut: preferredCut, hardCut: hardCut)
                ?? hardCut
            let overlapCount = segments.isEmpty ? 0 : min(overlap, cut - start)
            let segmentStart = start == 0 ? start : start - overlapCount
            segments.append(Segment(samples: samples[segmentStart..<cut], overlapSampleCount: overlapCount))
            start = cut
        }

        let overlapCount = segments.isEmpty ? 0 : min(overlap, samples.count - start)
        let segmentStart = start == 0 ? start : start - overlapCount
        segments.append(Segment(samples: samples[segmentStart..<samples.count], overlapSampleCount: overlapCount))
        return segments
    }

    /// Looks across the final five seconds before the three-minute hard boundary for the
    /// quietest 500 ms run. The RMS threshold is intentionally conservative: a questionable
    /// quiet patch is worse than using overlap at the hard boundary.
    private static func preferredSilenceCut(
        in samples: [Float],
        preferredCut: Int,
        hardCut: Int
    ) -> Int? {
        let frame = sampleRate / 50 // 20 ms
        let requiredFrames = 25 // 500 ms
        let searchStart = max(0, preferredCut - 5 * sampleRate)
        let searchEnd = hardCut
        guard searchEnd - searchStart >= requiredFrames * frame else { return nil }

        var best: (cut: Int, rms: Float)?
        var index = searchStart
        while index + requiredFrames * frame <= searchEnd {
            var total: Float = 0
            var silent = true
            for frameIndex in 0..<requiredFrames {
                let offset = index + frameIndex * frame
                var rms: Float = 0
                samples.withUnsafeBufferPointer { buffer in
                    vDSP_rmsqv(buffer.baseAddress!.advanced(by: offset), 1, &rms, vDSP_Length(frame))
                }
                // -44 dBFS: only a genuinely quiet run is considered a safe cut. This avoids
                // treating distant/soft speech as silence at the batch boundary.
                if rms > 0.0063 { silent = false; break }
                total += rms
            }
            if silent && (best == nil || total < best!.rms) {
                best = (index + (requiredFrames * frame / 2), total)
            }
            index += frame
        }
        return best?.cut
    }

    /// Removes only a long, exact normalized suffix/prefix match caused by audio overlap.
    /// Ambiguous or short repetitions are retained so intentional spoken repeats are never
    /// silently lost.
    static func joinTranscripts(_ texts: [String]) -> String {
        texts.reduce("") { combined, next in
            let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !combined.isEmpty else { return next }
            guard !next.isEmpty else { return combined }

            let left = combined.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let right = next.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let longest = min(12, left.count, right.count)
            var overlap = 0
            if longest >= 3 {
                for length in stride(from: longest, through: 3, by: -1) {
                    let leftWords = left.suffix(length).map(normalize)
                    let rightWords = right.prefix(length).map(normalize)
                    if leftWords == rightWords {
                        overlap = length
                        break
                    }
                }
            }
            let remainder = right.dropFirst(overlap).joined(separator: " ")
            return overlap == 0 ? "\(combined) \(next)" : "\(combined) \(remainder)"
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
