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

    /// Whisper's classic failure on music or noise: one word over and over ("Bu Bu Bu Bu Bu Bu"),
    /// or a whole transcript that is only a YouTube outro (`isKnownHallucination`).
    /// Nobody dictates a single word four or more times with nothing else around it.
    static func isRepetitionHallucination(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).map(normalize)
        return (words.count >= 4 && Set(words).count == 1) || isKnownHallucination(text)
    }

    /// Phrases Whisper invents on silence or noise: Turkish YouTube outros from its subtitle
    /// training data. Matched against the entire transcript (`isKnownHallucination`) or its
    /// very end (`removeTrailingOutros`), never at the start or in the middle of dictation.
    private static let knownHallucinations: Set<String> = [
        "abone ol", "abone olun", "abone olmayi unutmayin", "kanalima abone olun",
        "izlediginiz icin tesekkurler", "izlediginiz icin tesekkur ederim",
        "izlediginiz icin cok tesekkurler", "izlediginiz icin tesekkur ederiz",
        "videoyu begenmeyi unutmayin", "begenmeyi ve abone olmayi unutmayin",
        "bir sonraki videoda gorusmek uzere", "bir sonraki videoda gorusuruz",
        "altyazi m k",
    ]

    static func isKnownHallucination(_ text: String) -> Bool {
        let words = collapseRepetitionLoops(text)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { String($0) }
            .map(foldTurkish)
            .filter { !$0.isEmpty }
        return knownHallucinations.contains(words.joined(separator: " "))
    }

    /// Strips known outros from the end of a transcript that also has real speech ("yarın
    /// toplantı var. Abone olun." → "yarın toplantı var."). Whisper appends them when a
    /// recording ends in silence; several can stack, so this repeats until none is left.
    /// A transcript that is nothing but an outro is left for `isKnownHallucination`.
    static func removeTrailingOutros(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var removedAny = true
        while removedAny {
            removedAny = false
            let keys = words.map { foldTurkish($0.trimmingCharacters(in: .punctuationCharacters.union(.symbols))) }
            for phrase in knownHallucinations {
                let phraseWords = phrase.split(separator: " ").map(String.init)
                guard words.count > phraseWords.count,
                      Array(keys.suffix(phraseWords.count)) == phraseWords else { continue }
                words.removeLast(phraseWords.count)
                removedAny = true
                break
            }
        }
        let result = words.joined(separator: " ")
        guard result.count < text.count else { return text }
        // Drop a dangling separator the outro followed ("var, abone olun" → "var").
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
    }

    /// A Whisper decoding loop: a phrase of up to `maxLoopPhrase` words repeated back to back
    /// at least `minLoopRepeats` times ("abone ol abone ol abone ol abone ol …", compression
    /// ratio ~38 where speech is ~1). Each loop keeps one copy; three repeats stay, since
    /// people do say things three times.
    static func collapseRepetitionLoops(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let keys = words.map(normalize)
        var output: [String] = []
        var index = 0
        while index < words.count {
            var collapsed = false
            for length in 1...maxLoopPhrase where index + length * minLoopRepeats <= words.count {
                let phrase = keys[index..<index + length]
                var repeats = 1
                while index + (repeats + 1) * length <= words.count,
                      keys[(index + repeats * length)..<(index + (repeats + 1) * length)].elementsEqual(phrase) {
                    repeats += 1
                }
                if repeats >= minLoopRepeats {
                    // Keep the last copy: it carries the sentence's closing punctuation.
                    let lastCopy = index + (repeats - 1) * length
                    output.append(contentsOf: words[lastCopy..<lastCopy + length])
                    index += repeats * length
                    collapsed = true
                    break
                }
            }
            if !collapsed {
                output.append(words[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    private static let maxLoopPhrase = 6
    private static let minLoopRepeats = 4

    /// Lowercased with Turkish letters folded to ASCII ("İzlediğiniz" → "izlediginiz").
    private static func foldTurkish(_ word: String) -> String {
        word.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
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
