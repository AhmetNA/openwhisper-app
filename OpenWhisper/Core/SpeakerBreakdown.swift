import Foundation

/// How much of a batch was the user's voice, other people's voice, or voice the target-speaker
/// gate left undecided, and how loud each was. Same 30 ms energy frames, noise floor and margin
/// as `RecordingStatsAccumulator`. Levels are dBFS (digital full scale), not SPL.
struct SpeakerSplitLevels: Equatable, Sendable {
    struct Bucket: Equatable, Sendable {
        var frames = 0
        var powerSum: Double = 0

        var seconds: Double {
            Double(frames * RecordingStatsAccumulator.frameSamples) / Double(RecordingStatsAccumulator.sampleRate)
        }
        var dbfs: Double? { frames > 0 ? 10 * log10(max(powerSum / Double(frames), 1e-12)) : nil }

        static func + (a: Bucket, b: Bucket) -> Bucket {
            Bucket(frames: a.frames + b.frames, powerSum: a.powerSum + b.powerSum)
        }
    }

    var own = Bucket()
    var others = Bucket()
    var undecided = Bucket()
    var noiseFloorDBFS: Double?

    /// Own voice minus other voices, in dB: how far apart the two were for the gate.
    var gapDB: Double? {
        guard let own = own.dbfs, let others = others.dbfs else { return nil }
        return own - others
    }

    static func + (a: SpeakerSplitLevels, b: SpeakerSplitLevels) -> SpeakerSplitLevels {
        SpeakerSplitLevels(own: a.own + b.own, others: a.others + b.others, undecided: a.undecided + b.undecided,
                           noiseFloorDBFS: [a.noiseFloorDBFS, b.noiseFloorDBFS].compactMap { $0 }.min())
    }

    /// - Parameters:
    ///   - overlapSampleCount: leading samples repeated from the previous batch; skipped so they
    ///     are not counted twice.
    ///   - ownRanges: sample ranges the gate accepted as the user (indices into `samples`). Voiced
    ///     frames inside them are own voice, outside are others. `nil` when the gate made no
    ///     split (uncertain, ambiguous, filter error): every voiced frame is undecided.
    static func measure(samples: [Float], overlapSampleCount: Int, ownRanges: [TargetSpeakerAcceptedRange]?) -> SpeakerSplitLevels {
        let frameSamples = RecordingStatsAccumulator.frameSamples
        let start = min(max(0, overlapSampleCount), samples.count)
        var powers: [Double] = []
        var frameStart = start
        while frameStart + frameSamples <= samples.count {
            var sum: Double = 0
            for i in frameStart..<frameStart + frameSamples { sum += Double(samples[i]) * Double(samples[i]) }
            powers.append(sum / Double(frameSamples))
            frameStart += frameSamples
        }
        guard !powers.isEmpty else { return SpeakerSplitLevels() }
        let dbs = powers.map { 10 * log10(max($0, 1e-12)) }
        let floor = dbs.sorted()[dbs.count / 10]
        let threshold = max(floor + RecordingStatsAccumulator.speechMarginDB, RecordingStatsAccumulator.absoluteFloorDB)

        var result = SpeakerSplitLevels(noiseFloorDBFS: floor)
        for (index, power) in powers.enumerated() where dbs[index] >= threshold {
            guard let ownRanges else {
                result.undecided.frames += 1
                result.undecided.powerSum += power
                continue
            }
            let center = start + index * frameSamples + frameSamples / 2
            if ownRanges.contains(where: { $0.start <= center && center < $0.end }) {
                result.own.frames += 1
                result.own.powerSum += power
            } else {
                result.others.frames += 1
                result.others.powerSum += power
            }
        }
        return result
    }
}

/// One batch of a recording as the target-speaker gate saw it, for the recording's trace:
/// which words were heard in the user's voice, which in other voices, and how loud each was.
struct SpeakerBatchLog: Sendable {
    let batch: Int
    let decision: String
    let levels: SpeakerSplitLevels
    var ownText: String?
    var othersText: String?
    var uncertainText: String?
    var notes: [String] = []

    var lines: [String] {
        var head = "Batch \(batch): \(decision)"
        head += " | own \(Self.describe(levels.own))"
        head += " | others \(Self.describe(levels.others))"
        if levels.undecided.frames > 0 { head += " | undecided \(Self.describe(levels.undecided))" }
        if let gap = levels.gapDB { head += String(format: " | gap %.1f dB", gap) }
        if let floor = levels.noiseFloorDBFS { head += String(format: " | noise floor %.1f dBFS", floor) }
        var lines = [head]
        if let ownText { lines.append("  own voice: \"\(ownText)\"") }
        if let othersText { lines.append("  other voices: \"\(othersText)\"") }
        if let uncertainText { lines.append("  uncertain: \"\(uncertainText)\"") }
        lines += notes.map { "  note: \($0)" }
        return lines
    }

    static func describe(_ bucket: SpeakerSplitLevels.Bucket) -> String {
        guard let db = bucket.dbfs else { return "-" }
        return String(format: "%.1f s @ %.1f dBFS", bucket.seconds, db)
    }

    /// Header block for the trace: a totals line, everything heard per voice, then each batch.
    static func headerLines(targetSpeakerEnabled: Bool, batches: [SpeakerBatchLog]) -> [String] {
        guard targetSpeakerEnabled else {
            return ["Speakers: not split (\"Yalnızca Benim Sesim\" is off)"]
        }
        guard !batches.isEmpty else { return ["Speakers: no batch reached the speaker gate"] }
        let total = batches.map(\.levels).reduce(SpeakerSplitLevels(), +)
        func joined(_ texts: [String?]) -> String {
            texts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let own = joined(batches.map(\.ownText))
        let others = joined(batches.map(\.othersText))
        let uncertain = joined(batches.map(\.uncertainText))
        var summary = "Speakers: own \(RecordingStats.wordCount(in: own) ?? 0) words, \(describe(total.own))"
        summary += " | others \(RecordingStats.wordCount(in: others) ?? 0) words, \(describe(total.others))"
        if total.undecided.frames > 0 { summary += " | undecided \(describe(total.undecided))" }
        if let gap = total.gapDB { summary += String(format: " | gap %.1f dB", gap) }
        var lines = [summary]
        lines.append("Own voice heard: \(own.isEmpty ? "-" : "\"\(own)\"")")
        lines.append("Other voices heard: \(others.isEmpty ? "-" : "\"\(others)\"")")
        if !uncertain.isEmpty { lines.append("Uncertain voice heard: \"\(uncertain)\"") }
        return lines + batches.flatMap(\.lines)
    }
}
